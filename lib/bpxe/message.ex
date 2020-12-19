defmodule BPXE.Message do
  defstruct message_id: nil,
            content: nil,
            __txn__: 0,
            __gen__: nil

  use ExConstructor

  def new(options \\ []) do
    result = super(options)

    %{
      result
      | __txn__: {options[:activation] || 0, 0},
        message_id: result.message_id || generate_id(),
        __gen__: :atomics.new(2, [])
    }
  end

  def next_txn(%__MODULE__{__gen__: gen, __txn__: {activation, txn}}) do
    {activation,
     case :atomics.add_get(gen, 1, 1) do
       n when n < txn ->
         :atomics.add_get(gen, 2, 1) + 18_446_744_073_709_551_615

       n ->
         n
     end}
  end

  defp generate_id() do
    {m, f, a} = Application.get_env(:bpxe, :message_id_generator)
    apply(m, f, a)
  end

  def txn(%__MODULE__{__txn__: {_, txn}}), do: txn
  def activation(%__MODULE__{__txn__: {activation, _}}), do: activation
end
