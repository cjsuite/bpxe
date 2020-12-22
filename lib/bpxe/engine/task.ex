defmodule BPXE.Engine.Task do
  use GenServer
  use BPXE.Engine.FlowNode
  alias BPXE.Engine.{Process, Base}
  alias BPXE.Engine.Process.Log
  use BPXE.Engine.Blueprint.Recordable

  defstate(
    [id: nil, type: nil, options: %{}, blueprint: nil, process: nil, script: ""],
    persist: []
  )

  def start_link(id, type, options, blueprint, process) do
    start_link([{id, type, options, blueprint, process}])
  end

  def add_script(pid, script) do
    call(pid, {:add_script, script})
  end

  def init({id, type, options, blueprint, process}) do
    state = %__MODULE__{
      id: id,
      type: type,
      options: options,
      blueprint: blueprint,
      process: process
    }

    state = initialize(state)
    init_ack()
    enter_loop(state)
  end

  def handle_call({:add_script, script}, _from, state) do
    {:reply, {:ok, script}, %{state | script: script}}
  end

  def handle_token({token, _id}, %__MODULE__{type: :scriptTask} = state) do
    Process.log(state.process, %Log.TaskActivated{
      pid: self(),
      id: state.id,
      token_id: token.token_id
    })

    {:ok, vm} = BPXE.Language.Lua.new()
    process_vars = Base.variables(state.process)
    vm = BPXE.Language.set(vm, "process", process_vars)
    {:reply, flow_node_vars, state} = handle_call(:variables, :ignored, state)
    vm = BPXE.Language.set(vm, "flow_node", flow_node_vars)
    vm = BPXE.Language.set(vm, "token", token.payload)

    case BPXE.Language.eval(vm, state.script) do
      {:ok, {_result, vm}} ->
        process_vars = BPXE.Language.get(vm, "process")
        flow_node_vars = BPXE.Language.get(vm, "flow_node")
        token = %{token | payload: BPXE.Language.get(vm, "token")}
        Base.merge_variables(state.process, process_vars, token)

        {:reply, _, state} =
          handle_call({:merge_variables, flow_node_vars, token}, :ignored, state)

        Process.log(state.process, %Log.TaskCompleted{
          pid: self(),
          id: state.id,
          token_id: token.token_id
        })

        {:send, token, state}

      {:error, err} ->
        Process.log(state.process, %Log.ScriptTaskErrorOccurred{
          pid: self(),
          id: state.id,
          token_id: token.token_id,
          error: err
        })

        {:dontsend, state}
    end
  end

  @bpxe_spec BPXE.BPMN.ext_spec()

  def handle_token(
        {token, _id},
        %__MODULE__{type: :serviceTask, options: %{{@bpxe_spec, "name"} => service}} = state
      ) do
    Process.log(state.process, %Log.TaskActivated{
      pid: self(),
      id: state.id,
      token_id: token.token_id
    })

    payload =
      state.extensions
      |> Enum.filter(fn
        {:json, _} -> true
        _ -> false
      end)
      |> Enum.map(fn {:json, json} ->
        case json do
          json when is_function(json, 1) ->
            cb = fn expr ->
              process_vars = Base.variables(state.process)
              {:reply, flow_node_vars, _state} = handle_call(:variables, :ignored, state)

              vars = %{
                "process" => process_vars,
                "token" => token.payload,
                "flow_node" => flow_node_vars
              }

              # TODO: handle errors
              {:ok, result} = JMES.search(expr, vars)

              {result, &Jason.encode/1}
            end

            json.(cb)

          _ ->
            json
        end
      end)
      |> Enum.reverse()

    response =
      BPXE.Engine.Blueprint.call_service(state.blueprint.pid, service, %BPXE.Service.Request{
        payload: payload
      })

    token =
      if result_var = state.options[{@bpxe_spec, "resultVariable"}] do
        %{token | payload: Map.put(token.payload, result_var, response.payload)}
      else
        token
      end

    Process.log(state.process, %Log.TaskCompleted{
      pid: self(),
      id: state.id,
      token_id: token.token_id
    })

    {:send, token, state}
  end

  def handle_token({token, _id}, state) do
    Process.log(state.process, %Log.TaskActivated{
      pid: self(),
      id: state.id,
      token_id: token.token_id
    })

    Process.log(state.process, %Log.TaskCompleted{
      pid: self(),
      id: state.id,
      token_id: token.token_id
    })

    {:send, token, state}
  end
end
