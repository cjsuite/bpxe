defmodule BPXE.Engine.PrecedenceGateway do
  @moduledoc """
  *Note: This gateway is not described in BPMN 2.0. Currently it can only be
  added programmatically (not through BPMN XML document, at this time)*

  This gateway will only process the first blueprint of a received token
  (tracked by token_id) and send it out to a corresponding output. The
  correspondance is achieved by requiring the same number of incoming and
  outgoing sequence flows and they will be mapped directly, so that Nth incoming
  flow will trigger Nth outgoing flow.
  """
  use GenServer
  use BPXE.Engine.FlowNode
  use BPXE.Engine.Blueprint.Recordable
  alias BPXE.Engine.Process
  alias BPXE.Engine.Process.Log

  defstate([id: nil, options: %{}, blueprint: nil, process: nil, precedence: %{}],
    persist: ~w(precedence)a
  )

  def start_link(id, options, blueprint, process) do
    GenServer.start_link(__MODULE__, {id, options, blueprint, process})
  end

  def init({id, options, blueprint, process}) do
    state = %__MODULE__{id: id, options: options, blueprint: blueprint, process: process}
    state = initialize(state)
    {:ok, state}
  end

  def handle_token({%BPXE.Token{} = token, id}, state) do
    Process.log(state.process, %Log.PrecedenceGatewayActivated{
      pid: self(),
      id: state.id,
      token_id: token.token_id
    })

    case state.precedence[token.token_id] do
      nil ->
        Process.log(state.process, %Log.PrecedenceGatewayPrecedenceEstablished{
          pid: self(),
          id: state.id,
          token_id: token.token_id
        })

        state = %{state | precedence: Map.put(state.precedence, token.token_id, [id])}

        case corresponds_to(id, state) do
          nil ->
            # There's no mapping between these flows
            # Drop the token
            {:dontsend, state}

          outgoing ->
            # There's a mapping, send it there
            {:send, token, [outgoing], state}
        end

      precedence ->
        Process.log(state.process, %Log.PrecedenceGatewayTokenDiscarded{
          pid: self(),
          id: state.id,
          token_id: token.token_id
        })

        new_precedence = [id | precedence]

        if length(new_precedence) == length(state.incoming) == length(state.outgoing) do
          # We've received them all, drop it from the state
          {:dontsend, %{state | precedence: Map.delete(state.precedence, token.token_id)}}
        else
          # Drop the token
          {:dontsend,
           %{state | precedence: Map.put(state.precedence, token.token_id, new_precedence)}}
        end
    end
  end

  defp corresponds_to(id, state) do
    index = Enum.find_index(state.incoming, fn x -> x == id end)
    Enum.at(state.outgoing, index)
  end
end
