# http-doom

[![Run on Google Cloud](https://deploy.cloud.run/button.svg)](https://deploy.cloud.run)

Play Doom with HTTP1.1, no WebSockets or VNC needed!

    docker run -p 8080:8080 mattipaksula/http-doom

![screenshot](https://github.com/matti/http-doom/raw/master/screenshot.jpg)

Note: Dockerfile is broken because caddy keeps changing their syntax and the dockerfile used untagged
