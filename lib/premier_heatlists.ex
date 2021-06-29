defmodule PremierHeatlists do
  @list_url "https://www.ndcapremier.com/scripts/competitors.asp?cyi=899"

  def run() do
    # Do what You want with result, it will be a list of {:ok, body} | {:error, reason}

    competitor_nodes =
      @list_url
      |> HTTPoison.get!()
      |> Map.get(:body)
      |> Floki.parse_document!()
      |> Floki.find("a.competitor")

    competitors =
      Enum.map(competitor_nodes, fn {_, attrs, [name]} ->
        id = attrs |> Map.new() |> Map.get("data-competitor")
        url = "https://www.ndcapremier.com/scripts/heatlists.asp?cyi=899&id=#{id}&type=competitor"
        {id, name, url}
      end)

    total_competitors = Enum.count(competitor_nodes)
    Counter.start_link(0)

    heats_by_couple =
      competitors
      |> Enum.map(&fetch_heats(&1, total_competitors))
      |> Enum.chunk_every(10)
      |> Enum.flat_map(fn chunk ->
        chunk
        |> Enum.map(&Task.async(__MODULE__, :fetch_heats, [&1, total_competitors]))
        |> Enum.map(&Task.await(&1, 15_000))
      end)
      |> merge_couples()

    File.write("./heats_by_couple.json", JSON.encode!(heats_by_couple))

    couples_by_heat =
      Enum.reduce(heats_by_couple, %{}, fn {couple, heats}, acc ->
        heats
        |> Enum.map(fn heat -> {heat, [couple]} end)
        |> Map.new()
        |> Map.merge(acc, fn _heat, new_couples, existing_couples ->
          Enum.concat(new_couples, existing_couples)
        end)
      end)

    File.write("./couples_by_heat.json", JSON.encode!(couples_by_heat))
  end

  def fetch_heats({id, name, url}, total, retries \\ 2) do
    result =
      case HTTPoison.get(url) do
        {:ok, %HTTPoison.Response{status_code: 200, body: body}} ->
          couple_heats = parse_couple_heats(name, body)
          {:ok, couple_heats}

        {:ok, %HTTPoison.Response{status_code: 404}} ->
          {:error, "Not Found"}

        {:error, %HTTPoison.Error{reason: reason}} ->
          {:error, reason}

        _ ->
          {:error, "Other Status Code"}
      end

    result =
      if elem(result, 0) == :error && retries > 0 do
        :timer.sleep(4000)
        fetch_heats({id, name, url}, retries - 1)
      else
        result
      end

    Counter.increment()
    IO.puts("Loaded #{Counter.value()} of #{total}")
    result
  end

  defp parse_couple_heats(name, body) do
    doc = Floki.parse_document!(body)
    partner = parse_partner(doc)
    heats = parse_heats(doc)
    couple_heats = %{name: name, partner: partner, heats: heats}
    write_competitor_heats(couple_heats)
    IO.inspect(couple_heats)
  end

  defp parse_partner(doc) do
    case Floki.find(doc, "th.partner-name") do
      [{_, _, [partner_name]}] -> String.replace(partner_name, "With ", "")
      _ -> "N/A"
    end
  end

  defp parse_heats(doc) do
    doc
    |> Floki.find("td.heatlist-heat")
    |> Enum.flat_map(fn {_, _, heat_numbers} ->
      Enum.filter(heat_numbers, &is_binary/1)
    end)
  end

  defp merge_couples(entries) do
    entries
    |> Enum.reduce(%{}, fn %{name: name, partner: partner, heats: heats}, acc ->
      couple =
        [name, partner]
        |> Enum.sort()
        |> Enum.join(", ")

      Map.update(acc, couple, MapSet.new(heats), &MapSet.intersection(&1, MapSet.new(heats)))
    end)
    |> Enum.map(fn {couple, heats} -> {couple, MapSet.to_list(heats)} end)
    |> Map.new()
  end

  defp write_competitor_heats(couple_heats) do
    file = File.open!("./competitor_heats.txt", [:utf8, :append])
    IO.puts(file, JSON.encode(couple_heats))
    File.close(file)
  end
end
