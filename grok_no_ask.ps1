$env:HTTP_PROXY = "http://127.0.0.1:10809"
$env:HTTPS_PROXY = "http://127.0.0.1:10809"
$env:ALL_PROXY = "http://127.0.0.1:10809"
$env:NO_PROXY = "127.0.0.1"
$env:http_proxy = $env:HTTP_PROXY
$env:https_proxy = $env:HTTPS_PROXY
$env:all_proxy = $env:ALL_PROXY
$env:no_proxy = $env:NO_PROXY

grok