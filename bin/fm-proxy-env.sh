#!/bin/bash
# fm proxy env — dynamically resolve WSL2 gateway (IP changes on WSL restart)
# source this before gh research:  source /home/fm-captain/firstmate/bin/fm-proxy-env.sh
# then git clone / curl / gh will route through Windows host proxy:7890
FM_GW=$(ip route show default 2>/dev/null | head -1 | tr -s ' ' | cut -d' ' -f3)
if [ -z "$FM_GW" ]; then
  echo "fm-proxy-env: WARN no gateway IP resolved" >&2
  return 1 2>/dev/null || exit 1
fi
export http_proxy="http://$FM_GW:7890"
export https_proxy="http://$FM_GW:7890"
export HTTP_PROXY="http://$FM_GW:7890"
export HTTPS_PROXY="http://$FM_GW:7890"
export no_proxy="localhost,127.0.0.1,::1"
# git honors http_proxy env for https transports; also set no_proxy for local
echo "fm-proxy-env: proxy=http://$FM_GW:7890 (gateway resolved dynamically)"
