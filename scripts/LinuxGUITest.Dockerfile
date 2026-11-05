FROM pmt-linux-backend-test
RUN apt-get update && apt-get install -y --no-install-recommends \
    libgtk-4-1 xvfb dbus-x11 xauth xdotool \
    && rm -rf /var/lib/apt/lists/*
