#!/bin/bash
set -e

PACKAGE_NAME="peppyalsa"
VERSION="1.2"
REPO_URL="https://github.com/UncleRus/peppyalsa.git"
ARCHITECTURES=("amd64" "arm64" "armhf")
DISTRIBUTION="trixie"
WORK_DIR="$(pwd)/${PACKAGE_NAME}_build"
SOURCE_DIR="${WORK_DIR}/${PACKAGE_NAME}-${VERSION}"
RESULTS_DIR="${WORK_DIR}/results"

# Проверка Docker
if ! command -v docker >/dev/null 2>&1; then
    echo "Установка Docker..."
    apt-get update
    apt-get install -y docker.io
fi

# Подготовка
echo "Очистка рабочей директории..."
rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR" "$RESULTS_DIR"
cd "$WORK_DIR"

# Клонирование
echo "Клонирование репозитория..."
git clone "$REPO_URL" "${PACKAGE_NAME}-${VERSION}"

# Переходим в исходники для настройки
cd "${SOURCE_DIR}"

# Удаление каталога libs
echo "Удаление ненужного каталога libs..."
rm -rf libs/

# Применяем исправления для ошибок компиляции
echo "Применение исправлений для сборки..."

# 1. Исправление spectrum.c: несовместимый тип sa_handler
sed -i 's/disconnect_action\.sa_handler = \&reader_disconnect_handler;/disconnect_action.sa_handler = (void (*)(int))reader_disconnect_handler;/' src/spectrum.c

# 2. Исправление meter.c: несовместимый тип sa_handler
sed -i 's/disconnect_action\.sa_handler = \&reader_disconnect_handler;/disconnect_action.sa_handler = (void (*)(int))reader_disconnect_handler;/' src/meter.c

# 3. Исправление meter.c: несовместимый тип функции init
sed -i 's/_meter\.init = \&init;/_meter.init = (int (*)(const char *, int, int, int, int, int, int, int))init;/' src/meter.c

# 4. Исправление peppyalsa.c: несовместимые типы для snd_config_get_integer
# Сначала находим все объявления переменных, используемых с snd_config_get_integer
# и меняем их типы с int на long
sed -i 's/int meter_max;/long meter_max;/' src/peppyalsa.c
sed -i 's/int meter_show;/long meter_show;/' src/peppyalsa.c
sed -i 's/int spectrum_max;/long spectrum_max;/' src/peppyalsa.c
sed -i 's/int spectrum_size;/long spectrum_size;/' src/peppyalsa.c
sed -i 's/int log_f;/long log_f;/' src/peppyalsa.c
sed -i 's/int log_y;/long log_y;/' src/peppyalsa.c
sed -i 's/int s_factor;/long s_factor;/' src/peppyalsa.c
sed -i 's/int window;/long window;/' src/peppyalsa.c

# 5. Исправление spectrum.c: сравнение signed/unsigned
sed -i 's/for(m = 0; m < spectrum_size; m++)/for(m = 0; m < (int)spectrum_size; m++)/' src/spectrum.c

# 6. Убираем -Werror из флагов компиляции (чтобы предупреждения не останавливали сборку)
sed -i 's/-Werror=implicit-function-declaration//g' configure.ac configure.in Makefile.am src/Makefile.am 2>/dev/null || true

# Создаем debian файлы вручную
# ... предыдущий код ...

# Создаем debian файлы вручную
echo "Создание файлов Debian..."
mkdir -p debian
mkdir -p debian/source

echo "3.0 (quilt)" > debian/source/format

cat > debian/control << EOF
Source: ${PACKAGE_NAME}
Section: sound
Priority: optional
Maintainer: UncleRus <unclerus@gmail.com>
Build-Depends: debhelper-compat (= 13),
               dh-autoreconf,
               autoconf-archive,
               libasound2-dev,
               libfftw3-dev,
               pkg-config
Standards-Version: 4.6.0

Package: ${PACKAGE_NAME}
Architecture: any
Depends: \${shlibs:Depends}, \${misc:Depends},
         libasound2 (>= 1.0.16)
Description: Peppy ALSA plugin
 The plugin has the following functionality:
  - Sends VU Meter data to the named pipe
  - Sends Spectrum Analyzer data to the named pipe
EOF

cat > debian/rules << 'EOF'
#!/usr/bin/make -f

%:
	dh $@ --with=autoreconf

override_dh_auto_configure:
	dh_auto_configure -- --disable-static

# Устанавливаем в debian/tmp, где dh_install ожидает найти файлы
override_dh_auto_install:
	dh_auto_install --destdir=debian/tmp

override_dh_shlibdeps:
	dh_shlibdeps --dpkg-shlibdeps-params=--ignore-missing-info

override_dh_auto_build:
	dh_auto_build -- CFLAGS="-Wno-incompatible-pointer-types -Wno-unused-parameter -Wno-sign-compare -Wno-unused-result"
EOF

chmod +x debian/rules

# Создаем debian/install с правильным путем
cat > debian/install << 'EOF'
usr/lib/*/libpeppyalsa.so.*
usr/lib/*/libpeppyalsa.so
EOF

# Исключаем только .la файл, который не нужен в пакете
cat > debian/not-installed << 'EOF'
usr/lib/*/libpeppyalsa.la
EOF

cat > debian/changelog << EOF
${PACKAGE_NAME} (${VERSION}-1) unstable; urgency=medium

  * Initial release.
  * Applied patches for Debian Trixie compatibility

 -- Builder <builder@localhost>  $(date -R)
EOF

# ... продолжение скрипта ...
# Возвращаемся в рабочую директорию
cd "${WORK_DIR}"

# Сборка для каждой архитектуры с помощью Docker
for arch in "${ARCHITECTURES[@]}"; do
    echo "========================================="
    echo "Сборка для архитектуры: $arch"
    echo "========================================="

    # Создаем временную директорию для сборки
    BUILD_DIR="${WORK_DIR}/docker-build-${arch}"
    echo "Подготовка временной директории: $BUILD_DIR"
    rm -rf "${BUILD_DIR}"
    mkdir -p "${BUILD_DIR}"

    # Копируем исходники во временную директорию
    echo "Копирование исходников..."
    cp -r "${SOURCE_DIR}"/* "${BUILD_DIR}/"

    # Создаем Dockerfile для сборки
    echo "Создание Dockerfile..."
    cat > "${BUILD_DIR}/Dockerfile" << EOF
FROM debian:${DISTRIBUTION}-slim

# Для кросс-компиляции добавляем архитектуру
RUN if [ "${arch}" != "amd64" ]; then dpkg --add-architecture ${arch}; fi

# Установка зависимостей для сборки
RUN apt-get update && apt-get install -y --no-install-recommends \\
    build-essential \\
    devscripts \\
    debhelper \\
    dh-autoreconf \\
    autoconf-archive \\
    pkg-config \\
    libasound2-dev$(if [ "${arch}" != "amd64" ]; then echo ":${arch}"; fi) \\
    libfftw3-dev$(if [ "${arch}" != "amd64" ]; then echo ":${arch}"; fi) \\
    git \\
    wget \\
    ca-certificates \\
    quilt \\
    && rm -rf /var/lib/apt/lists/*

# Для кросс-компиляции устанавливаем кросс-компилятор
RUN if [ "${arch}" != "amd64" ]; then \\
    apt-get update && apt-get install -y --no-install-recommends \\
    crossbuild-essential-${arch} \\
    && rm -rf /var/lib/apt/lists/*; \\
fi

WORKDIR /build
COPY . .

# Применяем патчи через quilt
RUN if [ -d debian/patches ] && [ -f debian/patches/series ]; then \\
    quilt push -a || true; \\
fi

# Проверяем наличие autoconf файлов
RUN if [ -f configure.ac ] || [ -f configure.in ]; then \\
    autoreconf -i 2>/dev/null || true; \\
fi

# Создаем исходный tarball
RUN tar -czf ../${PACKAGE_NAME}_${VERSION}.orig.tar.gz .

# Собираем пакет с дополнительными флагами для отключения предупреждений
RUN if [ "${arch}" = "amd64" ]; then \\
    CFLAGS="-Wno-incompatible-pointer-types -Wno-unused-parameter -Wno-sign-compare" dpkg-buildpackage -us -uc -b; \\
else \\
    CFLAGS="-Wno-incompatible-pointer-types -Wno-unused-parameter -Wno-sign-compare" dpkg-buildpackage -a${arch} -us -uc -b; \\
fi
EOF

    # Переходим в директорию сборки
    cd "${BUILD_DIR}"

    # Сборка в Docker
    echo "Запуск Docker сборки..."
    docker build -t "build-${PACKAGE_NAME}-${arch}" .

    # Копируем собранные пакеты
    echo "Копирование результатов..."
    docker run --rm -v "${RESULTS_DIR}:/output" "build-${PACKAGE_NAME}-${arch}" \
        bash -c "cp -f /*.deb /output/ 2>/dev/null || echo 'Не удалось найти .deb файлы'"

    # Очистка Docker образа
    docker rmi "build-${PACKAGE_NAME}-${arch}" 2>/dev/null || true

    # Возвращаемся в рабочую директорию
    cd "${WORK_DIR}"

    echo "Сборка для $arch завершена"
done

echo "========================================="
echo "Сборка завершена!"
echo "Пакеты в ${RESULTS_DIR}:"
echo "========================================="
ls -la "${RESULTS_DIR}"/*.deb 2>/dev/null || echo "Нет собранных пакетов"
