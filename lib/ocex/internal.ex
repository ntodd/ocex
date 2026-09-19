defmodule OCEx.Internal do
  @moduledoc false

  # Internal evaluator support. This enclosing box is intentionally not the
  # precise measurement returned by OCEx.bounds/1 and must not replace it.
  def envelope(%OCEx.Shape{ref: ref}), do: OCEx.Native.call(:bounds_envelope, [ref])
  def envelope(_), do: {:error, :invalid_shape}

  def cut_removed(%OCEx.Shape{ref: body}, %OCEx.Shape{ref: tool}) do
    case OCEx.Native.call(:cut_removed, [body, tool]) do
      {:ok, {ref, volume}} -> {:ok, %OCEx.Shape{ref: ref}, volume}
      error -> error
    end
  end

  def cut_removed(_, _), do: {:error, :invalid_shape}
end
