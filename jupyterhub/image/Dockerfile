FROM jupyter/datascience-notebook:latest



RUN pip install --no-cache-dir jupyterlab-vim \
                               jupyter-archive \
                               jupyterlabcodetoc \
                               jupyterlab-spreadsheet-editor \
                               jupyter_theme_editor \
                               jupyterlab-spellchecker \
                               jupyterlab-code-formatter black isort \
                               jupyterlab_latex \
                               jupyterlab_notify \
                               jupyter-resource-usage \
                               jupyterlab-topbar-text \
                               jupyterlab-logout \
                               ipympl \
                               jupyterlab-git \
                               jupyterlab-github \
                               jupyterlab-gitlab \
                               jupyter-ai \
                               jupyterlab_autoversion \
                               jupyter-dash

ENV TRANSFORMERS_CACHE=/tmp/.cache
ENV TOKENIZERS_PARALLELISM=true

RUN pip install --no-cache-dir torch torchvision torchaudio \
                               jax jaxlib \
                               optax \
                               transformers datasets \
                               nltk \
                               plotly \
                               dash \
                               pytorch_lightning \
                               gradio \
                               sentencepiece \
                               seqeval
