# OrdersGatewayAvailabilitySlowBurn

Severity: ticket. Fix today.

More than 3% of `/work` and `/echo` requests in one namespace fail with a 5xx, over both the last 6 h and 30 m. That is 6 times the SLO budget, so the month's budget is gone in about 5 days. The `namespace` label is the environment.

## Check and fix

Same steps as [OrdersGatewayAvailabilityFastBurn](OrdersGatewayAvailabilityFastBurn.md#check). A steady low error rate often comes from one pod with a runtime fault, or a small `config.faultErrorRate` left in an env file.

## Done when

`slo:orders_availability_errors:ratio_rate30m{namespace="<namespace>"}` stays below `0.005`. The alert can take up to 30 minutes to resolve.
