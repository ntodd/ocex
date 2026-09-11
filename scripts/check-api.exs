# Check documentation/spec coverage of intentional public functions, not generated defaults.
apps = if Mix.Project.config()[:app] == :smith, do: [:smith], else: [:ocex]
issues = for app <- apps,
  module <- Application.spec(app, :modules),
  {:docs_v1, _, _, _, module_doc, _, entries} <- [Code.fetch_docs(module)],
  module_doc != :hidden,
  {{:function, name, arity}, _, _, doc, _} <- entries,
  name not in [:__struct__], doc != :hidden,
  reduce: [] do
    issues ->
      {:ok, specs} = Code.Typespec.fetch_specs(module)
      issues = if doc == :none, do: ["Missing documentation: #{inspect(module)}.#{name}/#{arity}" | issues], else: issues
      if List.keymember?(specs, {name, arity}, 0), do: issues,
        else: ["Missing typespec: #{inspect(module)}.#{name}/#{arity}" | issues]
end
if issues != [], do: raise(Enum.join(issues, "\n"))
IO.puts("Public API documentation and typespecs checked")
