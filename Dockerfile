# Runs the flasher UI with PlatformIO already installed, so the only thing you
# need on the host is Docker.
#
#   docker compose up --build
#
# The project itself is bind-mounted rather than copied in: the app writes
# include/secrets.h, include/device_config.h and platformio_local.ini into your
# working copy, and builds have to see your edits. That also keeps the image
# small and independent of the source, so it only rebuilds when this file
# changes.
#
# Flashing needs a serial port, and a container only has one if the host can
# hand it over. Linux can. Docker Desktop on macOS and Windows runs a Linux VM
# with no USB passthrough, so there the UI works but flashing and MAC capture
# cannot -- see the README.

FROM python:3.12-slim

# git: PlatformIO fetches some platforms and libraries over it.
# udev: pyserial reads it to describe ports in the port picker.
RUN apt-get update \
    && apt-get install -y --no-install-recommends git ca-certificates libudev1 \
    && rm -rf /var/lib/apt/lists/*

# Pinned so an image rebuilt in a year behaves like this one.
RUN pip install --no-cache-dir platformio==6.1.19 pyserial==3.5

# Toolchains land here, roughly 500MB once the ESP32 platform is installed.
# docker-compose.yml keeps it in a named volume so it survives a rebuild;
# without that, every rebuild re-downloads the whole toolchain.
ENV PLATFORMIO_CORE_DIR=/pio
RUN mkdir -p /pio && chmod 777 /pio

# The container is normally run as the host's own uid so that generated files
# are not left root-owned. That uid does not exist in here, so nothing may
# depend on a home directory or a passwd entry.
ENV HOME=/tmp \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1

WORKDIR /project
EXPOSE 8765

# 0.0.0.0 so Docker can reach it from outside the container. Publishing it is
# what makes it safe or not: docker-compose.yml binds it to 127.0.0.1 on the
# host, which is the only sensible way to expose an API that writes credentials.
CMD ["python3", "tools/flasher/app.py", "--host=0.0.0.0", "--no-browser"]
