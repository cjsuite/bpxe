defmodule BPEXE.Engine.ParallelGateway do
  use GenServer
  use BPEXE.Engine.FlowNode
  alias BPEXE.Engine.Process
  alias BPEXE.Engine.Process.Log

  defstate([id: nil, options: %{}, instance: nil, process: nil, tokens: %{}, drop_tokens: %{}],
    persist: ~w(tokens drop_tokens)a
  )

  def start_link(id, options, instance, process) do
    GenServer.start_link(__MODULE__, {id, options, instance, process})
  end

  def init({id, options, instance, process}) do
    state = %__MODULE__{id: id, options: options, instance: instance, process: process}
    state = initialize(state)
    {:ok, state}
  end

  def handle_message({%BPEXE.Message{} = msg, id}, state) do
    Process.log(state.process, %Log.ParallelGatewayReceived{
      pid: self(),
      id: state.id,
      token: msg.token,
      from: id
    })

    case state.incoming do
      [_] ->
        # only one incoming, we're done
        Process.log(state.process, %Log.ParallelGatewayCompleted{
          pid: self(),
          id: state.id,
          token: msg.token,
          to: state.outgoing
        })

        {:send, msg, state}

      [] ->
        # there's a message but it couldn't come from anywhere. What gives?
        Process.log(state.process, %Log.ParallelGatewayCompleted{
          pid: self(),
          id: state.id,
          token: msg.token,
          to: []
        })

        {:dontsend, state}

      _ ->
        # Join

        # If join threshold was already reached, drop a message
        drop_token = state.drop_tokens[msg.token]

        if !!drop_token do
          drop_token = drop_token - 1

          drop_tokens =
            if drop_token == 0 do
              Map.delete(state.drop_tokens, msg.token)
            else
              Map.put(state.drop_tokens, msg.token, drop_token)
            end

          {:dontsend, %{state | drop_tokens: drop_tokens}}
        else
          tokens = Map.update(state.tokens, msg.token, [msg], fn x -> [msg | x] end)
          messages = tokens[msg.token]

          join_threshold =
            (state.options[{BPEXE.spec_schema(), "joinThreshold"}] || "#{length(state.incoming)}")
            |> String.to_integer()

          if length(messages) == join_threshold do
            tokens = Map.delete(tokens, msg.token)

            message = %{hd(messages) | content: Enum.map(messages, fn m -> m.content end)}

            Process.log(state.process, %Log.ParallelGatewayCompleted{
              pid: self(),
              id: state.id,
              token: msg.token,
              to: state.outgoing
            })

            {:send, message,
             %{
               state
               | tokens: tokens,
                 drop_tokens:
                   Map.put(
                     state.drop_tokens,
                     msg.token,
                     length(state.incoming) - join_threshold
                   )
             }}
          else
            {:dontsend, %{state | tokens: tokens}}
          end
        end
    end
  end
end