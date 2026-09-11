defmodule OCEx.Native do
  @moduledoc false
  @on_load :load

  def load do
    :ocex |> :code.priv_dir() |> :filename.join(~c"ocex_nif") |> :erlang.load_nif(0)
  end

  def call(_operation, _arguments), do: :erlang.nif_error(:not_loaded)
end
