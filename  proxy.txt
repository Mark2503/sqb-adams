mkdir -p /etc/systemd/system/docker.service.d
printf '[Service]\nEnvironment="HTTP_PROXY=%s"\nEnvironment="HTTPS_PROXY=%s"\nEnvironment="NO_PROXY=localhost,127.0.0.1,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16"\n' "$PROXY" "$PROXY" > /etc/systemd/system/docker.service.d/proxy.conf
systemctl daemon-reload
systemctl restart docker
