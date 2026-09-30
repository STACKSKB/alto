secret = System.fetch_env!("WEBHOOK_SECRET")
{:ok, event_flow} = AltoObanExample.Runs.fetch("event_flow")

inbox_options = [
  repo: AltoObanExample.Repo,
  oban: Oban,
  worker: AltoObanExample.Worker,
  run: "event_flow"
]

:ok = AltoObanExample.Inbox.validate_options(inbox_options)

[
  provider: nil,
  runs: %{"event_flow" => event_flow},
  listeners: [
    {Alto.Contrib.Listeners.Webhook,
     port: 4748,
     endpoints: %{
       "/hooks/events" => %{
         verify: fn body, headers ->
           Alto.Contrib.Ingress.HMAC.verify(body, headers,
             secret: secret,
             header: "x-signature",
             encoding: :base64
           )
         end,
         identity: &Alto.Contrib.Ingress.IdentityHeader.extract(&1, header: "x-delivery-id"),
         on_event: &AltoObanExample.Inbox.admit(&1, &2, inbox_options)
       }
     }}
  ]
]
