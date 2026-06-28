# Jak dodać patch BORE scheduler

Gdy BORE dla twojej wersji kernela będzie dostępny:

1. Wejdź na https://github.com/firelzrd/bore-scheduler
2. Pobierz patch dla swojej wersji kernela, np.:
   `bore-6.x-patches/0001-linux6.x.y-bore5.x.x.patch`
3. Wrzuć go tutaj jako `patches/gaming/0001-bore-scheduler.patch`
4. System automatycznie zastosuje go przez `patch -p1` przed *.config

WAŻNE: pliki *.patch muszą być prawdziwymi diffami pasującymi
do wersji kernela z config.toml. Pliki *.config działają zawsze.
