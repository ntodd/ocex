defmodule OCEx.Shape do
  @moduledoc """
  An opaque handle to native geometry and topology.

  Returned by OCEx constructors, modeling operations, and topology queries.
  Pass it back to OCEx to measure or transform the shape. The resource remains
  alive while referenced by an Elixir term; retaining a subshape does not
  require retaining its parent term.

  Do not construct this struct or use its `:ref` field directly. Persist with
  `OCEx.to_brep/1` or `OCEx.write_step/2`; the handle is meaningful only in
  the VM that created it. There is no manual close or free operation.
  """
  @enforce_keys [:ref]
  defstruct [:ref]
  @opaque t :: %__MODULE__{ref: reference()}
end
