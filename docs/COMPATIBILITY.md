# Совместимость

MVN Deploy определяет систему по `/etc/os-release` и подбирает пакетный менеджер, firewall и систему служб.
Список систем совпадает с теми, которые поддерживает официальный установщик 3x-ui: он выбирает действия по полю `ID`.

## Матрица

| Семейство | `ID` | Минимальная версия | Пакеты | Firewall | Службы |
|---|---|---|---|---|---|
| Debian | `debian`, `ubuntu`, `armbian`, `raspbian` | Debian 11, Ubuntu 20.04 (новее принимаются) | apt | UFW | systemd |
| Производные Debian | любые с `ID_LIKE=debian` или `ubuntu` | как у основы | apt | UFW | systemd |
| RHEL | `rhel`, `almalinux`, `rocky`, `ol`, `centos` (Stream) | 8 | dnf (yum) | firewalld | systemd |
| Fedora | `fedora` | 39 | dnf | firewalld | systemd |
| Amazon Linux | `amzn` | 2023 | dnf | firewalld | systemd |
| Arch | `arch`, `manjaro`, `parch` | rolling | pacman | UFW | systemd |
| SUSE | `opensuse-leap`, `opensuse-tumbleweed` | Leap 15.5 | zypper | firewalld | systemd |
| Alpine | `alpine` | 3.18 | apk | UFW | OpenRC (экспериментально) |

Производные Arch (EndeavourOS, Garuda…) и SLES **не поддерживаются**: официальный установщик 3x-ui выбирает пакетный менеджер
по `ID`, а для незнакомых систем использует apt. Принудительный запуск: `MVN_ALLOW_UNSUPPORTED_OS=1`.

## Что проверено автоматически

CI (`.github/workflows/ci.yml`) на каждый коммит:

- lint (ShellCheck, `bash -n`, поиск секретов) и unit-тесты;
- **dry-run** в контейнерах: Debian 11/12/13, Ubuntu 20.04/22.04/24.04, AlmaLinux 8/9, Rocky 9, Oracle Linux 9, Fedora, Amazon Linux 2023,
  CentOS Stream 9, Arch, openSUSE Leap/Tumbleweed, Alpine: определение семейства, пакетного менеджера и план;
- **полная установка** на чистых Ubuntu 22.04 и 24.04: 3x-ui, HTTPS, UFW, fail2ban, BBR, повторный запуск и удаление.

Для RHEL-семейства, Arch, SUSE и Alpine полная установка на живом сервере ещё не прогонялась: это ближайший шаг.
Особенности, на которые стоит смотреть при первом запуске:

- **RHEL-семейство:** fail2ban берётся из EPEL (для Fedora и Amazon Linux из основных репозиториев; если пакета нет, установка идёт дальше без него);
  firewalld включается только после добавления правила SSH; правила ставятся в зону, которая обслуживает сетевой интерфейс по умолчанию.
- **Alpine:** нет bash по умолчанию (`apk add bash curl`); вместо systemd используется OpenRC.
- **SELinux:** MVN Deploy его не меняет.

## Архитектуры

`amd64` и `arm64` — основные. `armv7`, `armv6`, `armv5`, `386`, `s390x` публикует 3x-ui; MVN Deploy на них работает, но не тестируется (выводится предупреждение).
