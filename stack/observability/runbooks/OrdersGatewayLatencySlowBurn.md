# OrdersGatewayLatencySlowBurn

Severity: ticket. Fix today.

More than 3% of `/echo` and `/version` requests in one namespace take over 250 ms, over both the last 6 h and 30 m. That is 6 times the SLO budget, so the month's budget is gone in about 5 days. The `namespace` label is the environment.

## Check and fix

Same steps as [OrdersGatewayLatencyFastBurn](OrdersGatewayLatencyFastBurn.md#check). A slow burn is often steady load near the HPA maximum, or a node short of CPU.

## Done when

`slo:orders_latency_errors:ratio_rate30m{namespace="<namespace>"}` stays below `0.005`. The alert can take up to 30 minutes to resolve.
