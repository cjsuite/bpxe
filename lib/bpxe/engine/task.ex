defmodule BPXE.Engine.Task do
  use GenServer
  use BPXE.Engine.FlowNode
  use BPXE.Engine.Activity
  alias BPXE.Engine.{Process, Base}
  alias BPXE.Engine.Process.Log

  defstate type: nil, script: ""

  def start_link(element, attrs, model, process) do
    start_link([{element, attrs, model, process}])
  end

  def init({element, attrs, model, process}) do
    type = get_type(element)

    state =
      %__MODULE__{type: type}
      |> put_state(Base, %{
        attrs: attrs,
        model: model,
        process: process
      })

    state = initialize(state)
    init_ack()
    enter_loop(state)
  end

  def handle_call({:add_node, _ref, "script", _attrs}, _from, state) do
    {:reply, {:ok, {self(), :script}}, state}
  end

  def handle_call({:complete_node, :script, script}, _from, state) do
    {:reply, :ok, %{state | script: script}}
  end

  def handle_token({token, _id}, %__MODULE__{type: :scriptTask} = state) do
    base_state = get_state(state, BPXE.Engine.Base)

    Process.log(base_state.process, %Log.TaskActivated{
      pid: self(),
      id: base_state.attrs["id"],
      token_id: token.token_id
    })

    {:ok, vm} = BPXE.Language.Lua.new()
    process_vars = Base.variables(base_state.process)
    vm = BPXE.Language.set(vm, "process", process_vars)
    flow_node_vars = base_state.variables
    vm = BPXE.Language.set(vm, "flow_node", flow_node_vars)
    vm = BPXE.Language.set(vm, "flow", token.payload)

    case BPXE.Language.eval(vm, state.script) do
      {:ok, {_result, vm}} ->
        process_vars = BPXE.Language.get(vm, "process")
        flow_node_vars = BPXE.Language.get(vm, "flow_node")
        token = %{token | payload: BPXE.Language.get(vm, "flow")}
        Base.merge_variables(base_state.process, process_vars, token)

        {:reply, _, state} =
          handle_call({:merge_variables, flow_node_vars, token}, :ignored, state)

        Process.log(base_state.process, %Log.TaskCompleted{
          pid: self(),
          id: base_state.attrs["id"],
          token_id: token.token_id
        })

        {:send, token, state}

      {:error, err} ->
        Process.log(base_state.process, %Log.ScriptTaskErrorOccurred{
          pid: self(),
          id: base_state.attrs["id"],
          token_id: token.token_id,
          error: err
        })

        {:dontsend, state}
    end
  end

  defmodule ExpressionError do
    defexception error: nil, expression: nil

    @impl true
    def exception({expression, error}) do
      %ExpressionError{expression: expression, error: error}
    end

    @impl true
    def message(%__MODULE__{expression: expression, error: error}) do
      "Expression '#{expression}` failed to evaluate with: #{inspect(error)}"
    end
  end

  @bpxe_spec BPXE.BPMN.ext_spec()

  def handle_token(
        {token, _id},
        %__MODULE__{
          type: :serviceTask,
          __layers__: %{Base => %{attrs: %{{@bpxe_spec, "name"} => service} = attrs}}
        } = state
      ) do
    base_state = get_state(state, BPXE.Engine.Base)

    Process.log(base_state.process, %Log.TaskActivated{
      pid: self(),
      id: base_state.attrs["id"],
      token_id: token.token_id
    })

    timeout =
      if duration = attrs[{@bpxe_spec, "timeout"}] do
        case Timex.Duration.parse(duration) do
          {:ok, duration} ->
            Timex.Duration.to_milliseconds(duration) |> floor()

          {:error, _err} ->
            # TODO: log error?
            nil
        end
      else
        nil
      end

    try do
      payload =
        base_state.extensions
        |> Enum.filter(fn
          {:json, _} -> true
          _ -> false
        end)
        |> Enum.map(fn {:json, json} ->
          case json do
            json when is_function(json, 1) ->
              cb = fn expr ->
                process_vars = Base.variables(base_state.process)
                {:reply, flow_node_vars, _state} = handle_call(:variables, :ignored, state)

                vars = %{
                  "process" => process_vars,
                  "flow" => token.payload,
                  "flow_node" => flow_node_vars
                }

                result =
                  case JMES.search(expr, vars) do
                    {:ok, result} ->
                      result

                    {:error, error} ->
                      Process.log(base_state.process, %Log.ExpressionErrorOccurred{
                        pid: self(),
                        id: base_state.attrs["id"],
                        token_id: token.token_id,
                        expression: expr,
                        error: error
                      })

                      raise ExpressionError, {expr, error}
                  end

                {result, &Jason.encode/1}
              end

              json.(cb)

            _ ->
              json
          end
        end)
        |> Enum.reverse()

      response =
        BPXE.Engine.Model.call_service(
          base_state.model.pid,
          service,
          %BPXE.Service.Request{
            payload: payload
          },
          timeout
        )

      token =
        if result_var = base_state.attrs[{@bpxe_spec, "resultVariable"}] do
          %{token | payload: Map.put(token.payload, result_var, response.payload)}
        else
          token
        end

      Process.log(base_state.process, %Log.TaskCompleted{
        pid: self(),
        id: base_state.attrs["id"],
        token_id: token.token_id
      })

      {:send, token, state}
    catch
      %ExpressionError{expression: expression, error: error} ->
        Process.log(base_state.process, %Log.ExpressionErrorOccurred{
          pid: self(),
          id: base_state.attrs["id"],
          token_id: token.token_id,
          expression: expression,
          error: error
        })

        {:dontsend, state}

      :exit, {:timeout, _} ->
        Process.log(base_state.process, %Log.ServiceTimeoutOccurred{
          pid: self(),
          id: base_state.attrs["id"],
          token_id: token.token_id,
          timeout: timeout
        })

        {:dontsend, state}
    end
  end

  def handle_token({token, _id}, state) do
    base_state = get_state(state, BPXE.Engine.Base)

    Process.log(base_state.process, %Log.TaskActivated{
      pid: self(),
      id: base_state.attrs["id"],
      token_id: token.token_id
    })

    Process.log(base_state.process, %Log.TaskCompleted{
      pid: self(),
      id: base_state.attrs["id"],
      token_id: token.token_id
    })

    {:send, token, state}
  end

  defp get_type(name), do: String.to_atom(name)

  import BPXE.Engine.BPMN

  def add_script(pid, attrs, body \\ nil) do
    add_node(pid, "script", attrs, body)
  end
end
