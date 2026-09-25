secret = System.fetch_env!("WEBHOOK_SECRET")
{:ok, event_flow} = AltoObanExample.Runs.fetch("event_flow")

Alto.Config.new(
  provider: nil,
  runs: %{"event_flow" => event_flow},
  listeners: [
    {Alto.Listeners.Webhook,
     port: 4748,
     endpoints: [
       %{
         path: "/hooks/events",
         verify:
           {Alto.Ingress.HMAC,
            secret: secret, header: "x-signature", encoding: :base64},
         identity: {Alto.Ingress.IdentityHeader, header: "x-delivery-id"},
         on_event:
           {:enqueue,
            {AltoObanExample.Inbox,
             repo: AltoObanExample.Repo,
             oban: Oban,
             worker: AltoObanExample.Worker,
             run: "event_flow"}}
       }
     ]}
  ]
)
