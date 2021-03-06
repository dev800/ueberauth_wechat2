defmodule Ueberauth.Strategy.Wechat.OAuth do
  @moduledoc """
  An implementation of OAuth2 for wechat.

  To add your `client_id` and `client_secret` include these values in your configuration.

      config :ueberauth, Ueberauth.Strategy.Wechat.OAuth,
        client_id: System.get_env("WECHAT_APPID"),
        client_secret: System.get_env("WECHAT_SECRET")
  """
  use OAuth2.Strategy

  @defaults [
    strategy: __MODULE__,
    site: "https://api.weixin.qq.com",
    authorize_url: "https://open.weixin.qq.com/connect/oauth2/authorize",
    qrcode_authorize_url: "https://open.weixin.qq.com/connect/qrconnect",
    token_url: "https://api.weixin.qq.com/sns/oauth2/access_token",
    refresh_token_url: "https://api.weixin.qq.com/sns/oauth2/refresh_token"
  ]

  @doc """
  Construct a client for requests to Wechat.

  Optionally include any OAuth2 options here to be merged with the defaults.

      Ueberauth.Strategy.Wechat.OAuth.client(redirect_uri: "http://localhost:4000/auth/wechat/callback")

  This will be setup automatically for you in `Ueberauth.Strategy.Wechat`.
  These options are only useful for usage outside the normal callback phase of Ueberauth.
  """
  def client(opts \\ []) do
    @defaults
    |> Keyword.merge(opts[:config] || [])
    |> OAuth2.Client.new()
  end

  @doc """
  Provides the authorize url for the request phase of Ueberauth. No need to call this usually.
  """
  def authorize_url!(params \\ [], opts \\ []) do
    opts
    |> client
    |> OAuth2.Client.authorize_url!(params)
    |> Kernel.<>("#wechat_redirect")
  end

  def qrcode_authorize_url!(params \\ [], opts \\ []) do
    oauth_client = opts |> client()

    oauth_client
    |> OAuth2.Client.authorize_url!(params)
    |> String.replace(oauth_client.authorize_url, @defaults[:qrcode_authorize_url], global: false)
    |> Kernel.<>("#wechat_redirect")
  end

  def get(token, url, headers \\ [], opts \\ []) do
    case token do
      %OAuth2.AccessToken{other_params: %{"error_description" => error_description}} ->
        {:error, %OAuth2.Error{reason: error_description}}

      %OAuth2.AccessToken{access_token: access_token} ->
        url = "#{url}?#{%{access_token: access_token, openid: "xxx"} |> URI.encode_query()}"

        [token: token]
        |> client
        |> OAuth2.Client.get(url, headers, opts)

      _ ->
        {:error, %OAuth2.Error{reason: "access token params error"}}
    end
  end

  def get_token!(params \\ [], options \\ []) do
    headers = Keyword.get(options, :headers, [])
    options = Keyword.get(options, :options, [])
    client_options = Keyword.get(options, :client_options, [])
    client = OAuth2.Client.get_token!(client(client_options), params, headers, options)

    client.token.access_token
    |> Jason.decode!(keys: :atoms)
    |> _parse_access_token()
  end

  # https://mp.weixin.qq.com/wiki?t=resource/res_main&id=mp1421140842
  def refresh_token!(refresh_token, options \\ []) do
    headers = Keyword.get(options, :headers, [])
    options = Keyword.get(options, :options, [])
    client = Keyword.get(options, :client_options, []) |> client()

    url =
      "#{@defaults[:refresh_token_url]}?#{
        URI.encode_query(%{
          appid: client.client_id,
          grant_type: "refresh_token",
          refresh_token: refresh_token
        })
      }"

    url
    |> HTTPoison.get(headers)
    |> case do
      {:ok, %HTTPoison.Response{body: body, status_code: 200}} ->
        body
        |> Jason.decode!(keys: :atoms)
        |> _parse_access_token()

      _ ->
        {:error, %OAuth2.Error{reason: "Request Fail"}}
    end
  end

  defp _parse_access_token(body) do
    case body do
      %{errcode: error_code, errmsg: error_description} ->
        %OAuth2.AccessToken{
          other_params: %{
            "error" => "error_#{error_code}",
            "error_description" => error_description
          }
        }

      access_token ->
        expires_at = Timex.now() |> Timex.shift(seconds: access_token[:expires_in])

        %OAuth2.AccessToken{
          access_token: access_token[:access_token],
          expires_at: expires_at,
          refresh_token: access_token[:refresh_token],
          token_type: "Bearer",
          other_params: %{
            "scope" => access_token[:scope],
            "open_id" => access_token[:openid],
            "unionid" => access_token[:unionid]
          }
        }
    end
  end

  # Strategy Callbacks

  def authorize_url(client, params) do
    client
    |> put_param(:response_type, "code")
    |> put_param(:appid, client.client_id)
    |> put_param(:redirect_uri, client.redirect_uri)
    |> OAuth2.Strategy.AuthCode.authorize_url(params)
  end

  def get_token(client, params, headers) do
    {code, params} = Keyword.pop(params, :code, client.params["code"])

    unless code do
      raise OAuth2.Error, reason: "Missing required key `code` for `#{inspect(__MODULE__)}`"
    end

    client
    |> put_param(:appid, client.client_id)
    |> put_param(:code, code)
    |> put_param(:secret, client.client_secret)
    |> put_header("Accept", "application/json")
    |> OAuth2.Strategy.AuthCode.get_token(params, headers)
  end
end
