defmodule OCEx.Internal do
  @moduledoc false

  # Internal evaluator support. This enclosing box is intentionally not the
  # precise measurement returned by OCEx.bounds/1 and must not replace it.
  def envelope(%OCEx.Shape{ref: ref}), do: OCEx.Native.call(:bounds_envelope, [ref])
  def envelope(_), do: {:error, :invalid_shape}
end
