FROM rocker/r-ver

RUN apt-get update -y && apt-get upgrade -y && apt-get install -y python3 python3-pip python3-venv curl unzip git

RUN python3 -m pip install --upgrade pip
RUN pip install synapseclient

RUN git clone -b update-docker-pipeline https://github.com/pranavanba/recover-s3-synindex /root/recover-s3-synindex
RUN Rscript /root/recover-s3-synindex/install_requirements.R

RUN curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip" \
    && unzip awscliv2.zip \
    && ./aws/install

RUN curl "https://s3.amazonaws.com/session-manager-downloads/plugin/latest/ubuntu_64bit/session-manager-plugin.deb" -o "session-manager-plugin.deb" \
    && dpkg -i session-manager-plugin.deb

RUN curl -o /root/synapse_creds.sh https://raw.githubusercontent.com/Sage-Bionetworks-IT/service-catalog-ssm-access/main/synapse_creds.sh \
    && chmod +x /root/synapse_creds.sh

RUN mkdir -p /root/.aws

COPY config /root/.aws/config

RUN sed -i -e "s|\"<PERSONAL_ACCESS_TOKEN>\"|\"\${AWS_SYNAPSE_TOKEN}\"\n|g" \
    -e "s|/absolute/path/to/synapse_creds.sh|/root/synapse_creds.sh|g" \
    /root/.aws/config

CMD R -e "q()" \
    && sed -i -e "s|\${AWS_SYNAPSE_TOKEN}|$AWS_SYNAPSE_TOKEN|g"\
    -e "s|{{AWS_ACCESS_KEY_ID}}|$AWS_ACCESS_KEY_ID|g" \
    -e "s|{{AWS_SECRET_ACCESS_KEY}}|$AWS_SECRET_ACCESS_KEY|g" \
    -e "s|{{AWS_SESSION_TOKEN}}|$AWS_SESSION_TOKEN|g" \
    /root/.aws/config \
    && Rscript ~/recover-s3-synindex/data_sync.R
