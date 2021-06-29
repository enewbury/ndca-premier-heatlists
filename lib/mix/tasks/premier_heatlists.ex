defmodule Mix.Tasks.PremierHeatlists do
  use Mix.Task

  alias PremierHeatlists, as: Premier

  def run(_) do
    Application.ensure_all_started(:httpoison)
    Premier.run()
  end
end
