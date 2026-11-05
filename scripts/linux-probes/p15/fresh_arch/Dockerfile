FROM docker.io/library/archlinux@sha256:42217d5f09e11d3fe7ad3b309b7fde891d458464dab5d674e629073765610427

# Offizielle Pacman-Policy bleibt erhalten. Kein --nodeps, kein SigLevel-Override.
RUN pacman-key --init \
    && pacman -Syu --needed --noconfirm \
        glibc gcc-libs bubblewrap gtk4 python python-pillow python-gobject \
        python-cairo poppler-glib tesseract tesseract-data-eng tesseract-data-deu \
        pandoc-cli libheif libde265 ffmpeg xorg-server-xvfb dbus xdotool ttf-dejavu \
    && useradd --uid 1000 --create-home --shell /bin/bash pmtprobe \
    && gpgconf --homedir /etc/pacman.d/gnupg --kill all \
    && find /etc/pacman.d/gnupg/private-keys-v1.d -type f -delete \
    && pacman -Scc --noconfirm

CMD ["/usr/bin/bash"]
