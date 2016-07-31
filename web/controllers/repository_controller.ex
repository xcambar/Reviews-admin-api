defmodule ReviewMyCode.RepositoryController do
  @moduledoc """
  Provides operations on Github repositories
  """
  use ReviewMyCode.Web, :authenticated_controller
  alias ReviewMyCode.User
  alias ReviewMyCode.Repository

  def index(conn, _, user, _claims) do
    token = user
    |> User.auth_for(:github)
    |> Map.get(:token)
    handle(conn, fetch_repos(token))
  end

  def index_org(conn, %{"org"=> org}, user, _claims) do
    %{:token => token, :uid => uid} = user
    |> User.auth_for(:github)
    response = case org do
      _ when org == uid -> fetch_repos(token)
      _ -> fetch_repos(token, org)
    end
    handle(conn, response)
  end

  def status(conn, %{"owner"=> owner, "name"=> name}, _user, _claims) do
    ref = %{ owner: owner, name: name, provider: "github" }
    value = case Repository.find_by_reference(ref, Repo) do
      {:ok, repo} -> repo.enabled
      _ -> false
    end
    conn
    |> json(%{status: value})
  end

  def create_status(conn, %{"name"=> name, "owner"=> owner, "provider"=> provider}, user, _claims) do
    %{:token => token} = user
    |> User.auth_for(String.to_atom(provider))
    ref = %{ owner: owner, name: name, provider: provider }
    result = case Repository.find_by_reference(ref, Repo) do
      nil -> %Repository{name: name, owner: owner, provider: provider}
      repo -> repo
    end
    |> Repository.changeset(ref)
    |> Repo.insert_or_update
    case result do
      {:ok, repo} ->
        create_webhook(token, repo)
        conn |> send_resp(204, "")
      {:error, _} -> conn |> send_resp(400, "")
    end
  end

  defp create_webhook(token, repo) do
    client = Tentacat.Client.new(%{access_token: token})
    # FIXME This is a dev config, move to config.exs
    config = %{
      "name" => "web",
      "active" => true,
      "events" => [ "pull_request", "issue_comment", "issues"],
      "config" => %{
        "content_type" => "json",
        "url"=> "http://localhost:8080",
        "insecure_ssl"=> "1",
        "secret"=> repo.id
      }
    }
    Tentacat.Hooks.create(repo.owner, repo.name, config, client)
    # TODO Save hook ID in the DB
  end

  defp fetch_repos(token) do
    Tentacat.Client.new(%{access_token: token})
    |> Tentacat.Repositories.list_mine()
    |> Enum.map(&scrub_repo(&1))
  end

  defp fetch_repos(token, org) do
    client = Tentacat.Client.new(%{access_token: token})
    Tentacat.Repositories.list_orgs(org, client)
    |> Enum.map(&scrub_repo(&1))
  end

  defp scrub_repo(org) do
    { %{ "login"=> login, "avatar_url"=> avatar_url}, org } = Map.take(org, ["id", "owner", "full_name", "name"])
    |> Map.get_and_update("owner", fn(_)-> :pop end);
    Map.put(org, "avatar_url", avatar_url)
    |> Map.put("owner", login)
  end

  defp handle(conn, {_status, error}) do
    conn
    |> put_status(403)
    |> json(error)
  end

  defp handle(conn, response) do
    conn
    |> json(response)
  end

end
