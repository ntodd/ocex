# Run from either package with mix run scripts/check-guides.exs.
# Mix supplies dependencies; all other Elixir blocks run in document order.
package = File.cwd!()
paths = [Path.join(package, "README.md") | Path.wildcard(Path.join(package, "guides/*.md"))]
work = Path.join(System.tmp_dir!(), "cad-guides-#{System.unique_integer([:positive])}")
File.mkdir_p!(work)

try do
  File.cd!(work, fn ->
    for path <- paths do
      source = File.read!(path)
      blocks = Regex.scan(~r/```elixir\n(.*?)\n```/s, source, return: :index)

      Enum.reduce(blocks, {[], Code.env_for_eval(file: path)}, fn [_, {start, size}],
                                                                  {binding, env} ->
        line = source |> binary_part(0, start) |> String.split("\n") |> length()
        code = binary_part(source, start, size)
        quoted = Code.string_to_quoted!(code, file: path, line: line)

        forms =
          case quoted do
            {:__block__, _, forms} -> forms
            form -> [form]
          end

        forms =
          Enum.reject(forms, fn
            {{:., _, [{:__aliases__, _, [:Mix]}, :install]}, _, _} -> true
            _ -> false
          end)

        {_, binding, env} = Code.eval_quoted_with_env({:__block__, [], forms}, binding, env)

        for {name, value} <- binding do
          case value do
            %{__struct__: module} when module in [Smith.Model, Smith.Sketch, Smith.Assembly] ->
              case Smith.evaluate(value) do
                {:ok, _} -> :ok
                error -> raise "#{path}:#{line}: #{name} failed evaluation: #{inspect(error)}"
              end

            _ ->
              :ok
          end
        end

        {binding, env}
      end)

      IO.puts("Verified #{length(blocks)} Elixir blocks: #{Path.relative_to(path, package)}")
    end
  end)
after
  File.rm_rf!(work)
end
