FROM ubuntu:26.04
RUN apt update && \
  apt install -y python3 python3-numpy python3-matplotlib \
  gfortran gcc git \
  opam build-essential curl bubblewrap unzip sudo pipx make cmake ninja-build binutils \
  libhdf5-dev libopenblas-dev libmpich-dev

# RUN apt install -y libcoarrays-openmpi-dev libopenmpi-dev openmpi-bin

# Arguments to allow VS Code to pass in the correct UID/GID
ARG USERNAME=ubuntu
# ARG USER_UID=1000
# ARG USER_GID=$USER_UID

# # Create the user if it doesn't exist
# # The following logic is a safe way to ensure the user is present with sudo access
# RUN if ! id -u $USERNAME > /dev/null 2>&1; then \
#         groupadd --gid $USER_GID $USERNAME \
#         && useradd --uid $USER_UID --gid $USER_GID -m $USERNAME; \
#     fi \
#     && apt-get update \
#     && apt-get install -y sudo \
#     && echo $USERNAME ALL=\(root\) NOPASSWD:ALL > /etc/sudoers.d/$USERNAME \
#     && chmod 0440 /etc/sudoers.d/$USERNAME

RUN usermod -aG sudo $USERNAME
# Grant passwordless sudo to the ubuntu user
RUN echo "ubuntu ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/ubuntu && \
    chmod 0440 /etc/sudoers.d/ubuntu

# Set the default user for the container
USER $USERNAME

# Just for when mounting manually, not for dev container
RUN mkdir -p /home/$USERNAME/FortScript
RUN mkdir -p /home/$USERNAME/work