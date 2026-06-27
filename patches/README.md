# patches/

Tutaj umieszczaj własne pliki `*.patch` które zostaną zastosowane przez `patch -p1`
na drzewie źródeł kernela, **przed** krokiem konfiguracji.

Patche są stosowane alfabetycznie — numeruj pliki żeby kontrolować kolejność:

```
patches/
  0001-moj-pierwszy-patch.patch
  0002-drugi-patch.patch
  gaming/          ← patche gamingowe (np. BORE gdy nie można auto-pobrać)
  nvidia/          ← patche specyficzne dla NVIDIA
```

> **Uwaga:** Większość optymalizacji (HZ=1000, PREEMPT, BBR v3, NTSYNC, BORE config,
> NVIDIA tweaki itd.) jest nakładana automatycznie przez `KernelConfigurator`
> bezpośrednio na `.config` — **nie musisz tu nic wrzucać** żeby działały.
>
> Patche `patch -p1` są potrzebne tylko gdy chcesz zmienić **kod źródłowy** kernela,
> np. dodać łatkę BORE scheduler (jeśli `auto_fetch_patches = false`).
