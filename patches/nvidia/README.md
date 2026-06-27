# patches/nvidia/

Patche specyficzne dla NVIDIA stosowane na kod źródłowy kernela (`patch -p1`).

Większość konfiguracji NVIDIA (KALLSYMS_ALL, DMABUF_HEAPS, wyłączenie Nouveau,
ReBAR) jest nakładana automatycznie przez KernelConfigurator na .config.
