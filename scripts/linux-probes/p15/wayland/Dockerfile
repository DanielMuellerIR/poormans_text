FROM pmt-linux-arch-test:20261105

# Geprüfte lokale Basis: sha256:333a63abc2687d3c14a4e2e440f0f80e4e295a7db8b935623c8daaa8ba01f713
RUN pacman -Syu --needed --noconfirm weston \
    && gpgconf --homedir /etc/pacman.d/gnupg --kill all \
    && find /etc/pacman.d/gnupg/private-keys-v1.d -type f -delete \
    && find /var/cache/pacman/pkg -mindepth 1 -delete

CMD ["/usr/bin/bash"]
