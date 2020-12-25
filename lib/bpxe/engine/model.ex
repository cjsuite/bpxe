defmodule BPXE.Engine.Model do
  use GenServer

  use BPXE.Engine.Model.Recordable,
    handle:
      ~w(add_process add_event add_sequence_flow add_event_based_gateway add_exclusive_gateway
        add_inclusive_gateway add_precedence_gateway add_sensor_gateway add_signal_event_definition
        add_parallel_gateway add_condition_expression add_incoming add_outgoing add_task add_script
        add_extension_elements add_json add_standard_loop_characteristics add_loop_condition
      )a ++ if(Mix.env() == :test, do: [:add_flow_node], else: [])

  defmodule Config do
    defstruct flow_handler: nil, pid: nil, init_fn: nil, id: nil
    use ExConstructor
  end

  def start_link(config \\ []) do
    # Model identification has a little bit of an unusual twist.
    # We typically identify model by either:
    # 1. Model PID
    # 2. Model ID (can be supplied as `id` option or will be automatically generated)
    #
    # Why two? The (somewhat convoluted) thinking behind this is the following:
    #
    # Model ID is a "permanent" ID that survives restarts. Therefore, things like
    # flow handlers that store and restore states should use this permanent IDs to identify
    # their records.
    #
    # Model PID is transient and will be changed at every restart, so we don't use this
    # for restarts. However, it *is* used as a component of `syn` pub/sub groups to identify this
    # particular worker of the model so that there is no chance these can be mixed up and wrong
    # tokens get to wrong groups at a wrong time.
    #
    # FIXME: is this thinking sound or am I over-engineering here?
    config = Config.new(config)
    config = %{config | id: config.id || generate_id()}

    case GenServer.start_link(__MODULE__, config) do
      {:ok, pid} ->
        GenServer.call(pid, :notify_when_initialized)
        {:ok, pid}

      error ->
        error
    end
  end

  def add_process(pid, id, options) do
    call(pid, {:add_process, id, options})
  end

  def processes(pid) do
    call(pid, :processes)
  end

  def provision_processes(pid) do
    processes = processes(pid)

    if Enum.empty?(processes) do
      {:error, :no_processes}
    else
      Enum.map(processes, fn id ->
        {id, provision_process(pid, id)}
      end)
    end
  end

  def provision_process(pid, process_id) do
    GenServer.call(pid, {:provision_process, process_id})
  end

  def start(pid) do
    processes = processes(pid)

    if Enum.empty?(processes) do
      {:error, :no_processes}
    else
      Enum.map(processes, fn id ->
        {id, start(pid, id)}
      end)
    end
  end

  def start(pid, process_id) do
    case :syn.whereis({pid, :process, process_id}) do
      :undefined ->
        provision_process(pid, process_id)
        start(pid, process_id)

      process ->
        BPXE.Engine.Process.start(process)
    end
  end

  def synthesize(pid) do
    for process <- processes(pid) do
      pid = :syn.whereis({pid, :process, process})
      BPXE.Engine.Process.synthesize(pid)
    end
  end

  def config(pid) do
    GenServer.call(pid, :config)
  end

  def model(pid) do
    GenServer.call(pid, :model)
  end

  def register_service(pid, name, service) do
    :syn.register({BPXE.Service, pid, name}, service)
    BPXE.Service.registered(service, pid, name)
  end

  def call_service(pid, name, request) do
    case find_service(pid, name) do
      nil -> nil
      service -> BPXE.Service.call(service, request, pid)
    end
  end

  def find_service(pid, name) do
    case :syn.whereis({BPXE.Service, pid, name}) do
      :undefined -> nil
      pid when is_pid(pid) -> pid
    end
  end

  def save_state(%Config{flow_handler: nil}, _generation, _id, _pid, _state) do
    :ok
  end

  def save_state(
        %Config{flow_handler: handler, pid: model, id: model_id},
        generation,
        id,
        pid,
        state
      )
      when is_atom(handler) do
    handler.save_state(model, generation, model_id, id, pid, state, nil)
  end

  def save_state(
        %Config{flow_handler: %{__struct__: handler} = config, pid: model, id: model_id},
        generation,
        id,
        pid,
        state
      ) do
    handler.save_state(model, generation, model_id, id, pid, state, config)
  end

  def save_state(model, generation, id, pid, state) when is_pid(pid) do
    model |> config() |> save_state(generation, id, pid, state)
  end

  def commit_state(%Config{flow_handler: nil}, _generation, _id) do
    :ok
  end

  def commit_state(
        %Config{flow_handler: handler, pid: model, id: model_id},
        generation,
        id
      )
      when is_atom(handler) do
    handler.commit_state(model, model_id, generation, id, nil)
  end

  def commit_state(
        %Config{flow_handler: %{__struct__: handler} = config, pid: model, id: model_id},
        generation,
        id
      ) do
    handler.commit_state(model, generation, model_id, id, config)
  end

  def commit_state(model, generation, id) when is_pid(model) do
    model |> config() |> commit_state(generation, id)
  end

  def restore_state(%Config{flow_handler: nil}) do
    {:error, :no_flow_handler}
  end

  def restore_state(%Config{
        flow_handler: %{__struct__: handler} = config,
        pid: model,
        id: model_id
      }) do
    if function_exported?(handler, :restore_state, 3) do
      handler.restore_state(model, model_id, config)
    else
      {:error, :not_supported}
    end
  end

  def restore_state(model) when is_pid(model) do
    model |> config() |> restore_state()
  end

  defstruct config: %{}, notify_when_initialized: nil, model: %{}

  def init(config) do
    {:ok, %__MODULE__{config: %{config | pid: self()}}, {:continue, :init_fn}}
  end

  def handle_continue(:init_fn, state) do
    pid = self()

    spawn_link(fn ->
      (state.config.init_fn || fn _ -> :ok end).(pid)
      GenServer.cast(pid, :initialized)
    end)

    {:noreply, state}
  end

  def handle_call(
        :notify_when_initialized,
        _from,
        %__MODULE__{notify_when_initialized: :done} = state
      ) do
    {:reply, :ok, state}
  end

  def handle_call(:notify_when_initialized, from, state) do
    {:noreply, %{state | notify_when_initialized: from}}
  end

  def handle_call(:processes, _from, state) do
    processes =
      Enum.filter(state.model[nil] || [], fn
        %Ref{payload: {:add_process, _, _options}} -> true
        _ -> false
      end)
      |> Enum.map(fn %Ref{payload: {:add_process, id, _options}} -> id end)

    {:reply, processes, state}
  end

  def handle_call(:config, _from, state) do
    {:reply, state.config, state}
  end

  def handle_call(:model, _from, state) do
    {:reply, state.model |> Enum.map(fn {k, v} -> {k, Enum.reverse(v)} end) |> Map.new(), state}
  end

  def handle_call({:provision_process, id}, _from, state) do
    alias BPXE.Engine.Model.Recordable.Ref

    ref =
      Enum.find(state.model[nil], fn
        %Ref{payload: {:add_process, ^id, _options}} ->
          true

        _ ->
          false
      end)

    if ref do
      %Ref{payload: {:add_process, ^id, options}} = ref

      case BPXE.Engine.Process.start_link(id, options, state.config) do
        {:ok, pid} ->
          {:reply, execute_model(ref, {:ok, pid}, pid, state), state}

        {:error, reason} ->
          {:reply, {:error, reason}, state}
      end
    else
      {:reply, {:error, :process_not_found}, state}
    end
  end

  def handle_cast(:initialized, state) do
    if state.notify_when_initialized do
      GenServer.reply(state.notify_when_initialized, :ok)
    end

    {:noreply, %{state | notify_when_initialized: :done}}
  end

  defp execute_model(ref, result, pid, state) do
    alias BPXE.Engine.Model.Recordable.Ref

    Enum.reduce((state.model[ref] || []) |> Enum.reverse(), result, fn
      _, {:error, _} = error ->
        error

      %Ref{payload: payload} = ref_, acc ->
        result =
          case pid do
            {module, arg} ->
              apply(module, :subcall, [arg, payload])

            pid when is_pid(pid) ->
              GenServer.call(pid, payload)
          end

        case result do
          {:error, reason} ->
            {:error, {payload, reason}}

          {:ok, pid_} ->
            execute_model(ref_, acc, pid_, state)

          :ok ->
            acc
        end
    end)
  end

  defp generate_id() do
    {m, f, a} = Application.get_env(:bpxe, :spec_id_generator)
    apply(m, f, a)
  end
end