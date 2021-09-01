#!/bin/bash
set -e -u -x

#TODO: check if is a valid call (this is an auxiliary script)

function repair_wheel {
    wheel="$1"
    if ! auditwheel show "$wheel"; then
        echo "Skipping non-platform wheel $wheel"
    else
        auditwheel repair "$wheel" --plat "$PLAT" -w /io/wheelhouse/
    fi
}

# Compile wheels
pushd /io
rm -f wheelhouse/* >/dev/null || true
for PYBIN in /opt/python/cp*/bin; do
    "${PYBIN}/python" -m build -x --wheel --outdir /tmp/wheelhouse/ .
done

# Bundle external shared libraries into the wheels
for whl in /tmp/wheelhouse/*.whl; do
    repair_wheel "$whl"
done
chown -R $USER_ID:$GROUP_ID /io/wheelhouse/
for whl in /io/wheelhouse/*.whl; do
    unzip -Z -l "$whl"
done

# Install package
for PYBIN in /opt/python/cp*/bin/; do
    PYTHON=${PYBIN}/python
    #${PYTHON} -m pip install -U importlib-metadata
    ${PYTHON} -m pip install --no-deps --no-index -f /io/wheelhouse cx_Freeze
    ${PYTHON} -m cx_Freeze --version
done
popd
