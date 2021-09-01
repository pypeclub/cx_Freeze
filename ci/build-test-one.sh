#!/bin/bash

if [ -z "$CONDA_DEFAULT_ENV" ] &&
   [ -z "$GITHUB_WORKSPACE" ] &&
   [ -z "$VIRTUAL_ENV" ]
then
	echo "Required: use of a virtual environment."
	exit 1
fi

if [ -z "$1" ] ; then
	echo "Usage: $0 sample"
	echo "Where:"
	echo "  sample is the name in samples directory (e.g. cryptography)"
	exit 1
fi
TEST_SAMPLE=$1

set -e

echo "::group::Prepare the environment"
# Get script directory (without using /usr/bin/realpath)
pushd $(dirname "${BASH_SOURCE[0]}")
CI_DIR=$(pwd)
# This script is on ci subdirectory
cd ..
TOP_DIR=$(pwd)
popd
# Constants
PY_PLATFORM=$(python -c "import sysconfig; print(sysconfig.get_platform())")
PY_VERSION=$(python -c "import sysconfig; print(sysconfig.get_python_version())")
if [ "$OSTYPE" == "msys" ] ; then
    echo "Install screenCapture in Windows/MSYS2"
    mkdir -p $HOME/bin
    pushd $HOME/bin
    if ! [ -e screenCapture.bat ] ; then
        curl https://raw.githubusercontent.com/npocmaka/batch.scripts/master/hybrids/.net/c/screenCapture.bat -O
        cmd //c screenCapture.bat
    fi
    popd
fi
# Valid the bdist_mac action
TEST_BDIST=0
if [[ $OSTYPE == darwin* ]] && ! [ -z "$TEST_BDIST_MAC" ] ; then
    TEST_BDIST=MAC
fi
echo "::endgroup::"

echo "::group::Check if $TEST_SAMPLE sample exists"
# Check if the samples is in current directory or in a cx_Freeze tree
if [ -d "$TEST_SAMPLE" ] ; then
    pushd $TEST_SAMPLE
    TEST_DIR=$(pwd)
    echo "Directory found"
else
    TEST_DIR=${TOP_DIR}/cx_Freeze/samples/$TEST_SAMPLE
    if [ -d "$TEST_DIR" ] ; then
        pushd $TEST_DIR
        echo "Directory found"
    else
        echo "ERROR: Sample's directory not found"
    fi
fi
echo "::endgroup::"
if ! [ -d "$TEST_DIR" ] ; then
    exit 1
fi

echo "::group::Install dependencies for $TEST_SAMPLE sample"
WHEELHOUSE="${TOP_DIR}/wheelhouse"
export PIP_FIND_LINKS=$WHEELHOUSE
export PIP_DISABLE_PIP_VERSION_CHECK=1
python ${CI_DIR}/build-test-json.py $TEST_DIR req
TEST_CXFREEZE="import cx_Freeze; print(cx_Freeze.__version__)"
if [ -e Pipfile ] ; then
    if ! pipenv run python -c "${TEST_CXFREEZE}" 2>/dev/null; then
        if [ -d $WHEELHOUSE ] ; then
            echo "::endgroup::"
            echo "::group::Install cx-freeze from wheelhouse"
            pipenv run pip install --no-deps --no-index cx_Freeze
        fi
    fi
elif ! [ -z "$CONDA_DEFAULT_ENV" ] ; then
    if ! python -c "${TEST_CXFREEZE}" 2>/dev/null; then
        echo "::endgroup::"
        echo "::group::Install cx-freeze from directory of the project"
        # Build the project using the conda python (do not use wheelhouse)
        if [[ $PY_PLATFORM == macos* ]] && ! [ -z "$SDKROOT" ] ; then
            pushd "$SDKROOT/.."
            export SDKROOT=$(pwd)/$(ls -1d MacOSX11.*.sdk | head -n1)
            popd
        fi
        pushd $TOP_DIR
        pip install -e . --no-deps --ignore-installed --no-cache-dir -v
        popd
    fi
else
    if ! python -c "${TEST_CXFREEZE}" 2>/dev/null; then
        echo "::endgroup::"
        if [ -d $WHEELHOUSE ] ; then
            echo "::group::Install cx-freeze from wheelhouse"
            pip install --no-deps --no-index cx_Freeze
        else
            echo "::group::Install cx-freeze from directory of the project"
            pushd $TOP_DIR
            pip install -e . --no-deps --ignore-installed --no-cache-dir -v
            popd
        fi
    fi
fi
echo "::endgroup::"

echo "::group::Show packages"
if [ -e Pipfile ] ; then
    pipenv graph
elif ! [ -z "$CONDA_DEFAULT_ENV" ] ; then
    $CONDA_EXE list -n $CONDA_DEFAULT_ENV
else
    pip list -v
fi
echo "::endgroup::"

echo "::group::Freeze $TEST_SAMPLE sample"
if [ -e Pipfile ] ; then
    pipenv run python setup.py build_exe --excludes=tkinter --include-msvcr=true --silent
else
    if [ "$TEST_BDIST" == "MAC" ]; then
        python setup.py build_exe --excludes=tkinter --silent bdist_mac
    else
        python setup.py build_exe --excludes=tkinter --include-msvcr=true --silent
    fi
fi
echo "::endgroup::"

echo "::group::Prepare to run $TEST_SAMPLE sample"
popd
BUILD_DIR="${TEST_DIR}/build/exe.${PY_PLATFORM}-${PY_VERSION}"
pushd ${BUILD_DIR}
count=0
TEST_NAME=$(python ${CI_DIR}/build-test-json.py $TEST_SAMPLE $count)
TEST_PIDS=
echo "::endgroup::"
until [ -z "$TEST_NAME" ] ; do
    # check the app type and remove that info from the app name
    if [[ $TEST_NAME == gui:* ]] ; then
        TEST_APPTYPE=gui
        TEST_NAME=${TEST_NAME:4}
    elif [[ $TEST_NAME == svc:* ]] ; then
        TEST_APPTYPE=svc
        TEST_NAME=${TEST_NAME:4}
    elif [[ $TEST_NAME == cmd:* ]] ; then
        TEST_APPTYPE=cmd
        TEST_NAME=${TEST_NAME:4}
    else
        TEST_APPTYPE=cui
    fi
    echo "::group::Run $TEST_NAME"
    # log name
    TEST_OUTPUT=$TEST_SAMPLE-$TEST_NAME-$PY_PLATFORM-$PY_VERSION
    # adjust the app name if run on bdist_mac
    if [ "$TEST_BDIST" == "MAC" ]; then
        set -x
        echo $TEST_NAME
        ls -d ../*.app
        TEST_NAME=$(ls -d ../*.app | awk '{print $1}')/Contents/MacOS/$TEST_NAME
        echo $TEST_NAME
        set +x
    fi
    # prepare the environment and run the app
    if [ "$TEST_APPTYPE" == "gui" ] ; then
        # GUI app is started in backgound to not block the execution
        if ! [ -z "$GITHUB_WORKSPACE" ] ; then
            # activate the Xvfb as virtual display in the GA (wait to start)
            if [ "$OSTYPE" == "linux-gnu" ] ; then
                /sbin/start-stop-daemon --start --quiet \
                  --pidfile /tmp/custom_xvfb_99.pid --make-pidfile \
                  --background --exec \
                  /usr/bin/Xvfb -- :99 -screen 0 1024x768x16 -ac +extension GLX
                  # +render -noreset
                sleep 10
                export DISPLAY=:99.0
            fi
        fi
        # run the app (wait to render)
        ./$TEST_NAME &> "${TEST_OUTPUT}.log" &
        TEST_PIDS="${TEST_PIDS}$! "
        # make a screen snapshot
        if [[ $OSTYPE == darwin* ]] ; then
            if [ -e /usr/sbin/screencapture ] ; then
                /usr/sbin/screencapture -T 30 "${TEST_OUTPUT}.png"
                echo "Taking a capture of the whole screen to ${TEST_OUTPUT}.png"
            else
                echo "WARNING: screencapture not found"
            fi
        elif [ "$OSTYPE" == "linux-gnu" ] ; then
            if which gnome-screenshot &>/dev/null ; then
                gnome-screenshot --delay=10 --file="${TEST_OUTPUT}.png"
                echo "Taking a capture of the whole screen to"
                echo "file://${PWD}/${TEST_OUTPUT}.png"
            else
                echo "WARNING: gnome-screenshot not found, use ImageMagick"
                if which import &>/dev/null ; then
                    sleep 10
                    import -window root "${TEST_OUTPUT}.png"
                    echo "Taking a capture of the whole screen to"
                    echo "file://${PWD}/${TEST_OUTPUT}.png"
                else
                    echo "WARNING: fallback ImageMagick not found"
                fi
            fi
        elif [ "$OSTYPE" == "msys" ] ; then
            if [ -e $HOME/bin/screenCapture.exe ] ; then
                sleep 15
                $HOME/bin/screenCapture.exe "${TEST_OUTPUT}.png"
            else
                echo "WARNING: screenCapture not found"
            fi
        fi
    elif [ "$TEST_APPTYPE" == "svc" ] ; then
        # service app is started in backgound too
        ./$TEST_NAME &> "${TEST_OUTPUT}.log" &
        TEST_PIDS="${TEST_PIDS}$! "
    elif [ "$TEST_APPTYPE" == "cmd" ] ; then
        # run a command on current console
        printf '=%.0s' {1..40}; echo
        echo $TEST_NAME
        echo $TEST_NAME | bash
        printf '=%.0s' {1..40}; echo
    else
        # Console app outputs on current console
        if [ "$OSTYPE" == "msys" ] && [ -z "$GITHUB_WORKSPACE" ] ; then
            # except in msys2 (use mintty to simulate a popup)
            (mintty --hold always -e ./${TEST_NAME})&
            TEST_PIDS="${TEST_PIDS}$! "
        else
            printf '=%.0s' {1..40}; echo
            ./$TEST_NAME
            TEST_PIDS="${TEST_PIDS}$! "
            printf '=%.0s' {1..40}; echo
        fi
    fi
    echo "::endgroup::"
    # next
    count=$(( $count + 1 ))
    TEST_NAME=$(python ${CI_DIR}/build-test-json.py $TEST_SAMPLE $count)
done
# check for backgound process
echo "::group::Check for exit codes"
TEST_EXITCODE=0
for TEST_PID in $TEST_PIDS ; do
    if kill -0 $TEST_PID ; then
        kill -9 $TEST_PID
        echo "Process $TEST_PID killed after 5 to 30 seconds"
    fi
    if wait $TEST_PID ; then
        echo "Process $TEST_PID success"
    else
        TEST_EXITCODE=$?
        ls -l *.log
        TEST_LOG_HAS_ERROR=N
        for TEST_LOG in *.log; do
            if [ $(wc -c $TEST_LOG | awk '{print $1}') != 0 ] ; then
                # generic erros and
                # error for pyside2
                # error for pyqt5
                if grep -q -i "error:" $TEST_LOG ||
                   grep -q -i "Unable to import shiboken" $TEST_LOG ||
                   grep -q -i "Reinstalling the application may fix this problem." $TEST_LOG
                then
                    # ignore error for wxPython 4.1.1
                    # https://github.com/wxWidgets/Phoenix/commit/040c59fd991cd08174b5acee7de9418c23c9de33
                    if [ "$OSTYPE" == "msys" ] &&
                       [ "$TEST_SAMPLE" == "matplotlib" ] &&
                       [ $(grep -q -i "error:" $TEST_LOG | wc -l | awk '{print $1}') == 1 ] &&
                       grep -q 'Error: Unable to set default locale:' $TEST_LOG
                    then
                        continue
                    fi
                    TEST_LOG_HAS_ERROR=Y
                    echo "$TEST_LOG"
                    cat $TEST_LOG
                fi
            fi
        done
        if [ $TEST_LOG_HAS_ERROR == Y ]; then
            echo "Process $TEST_PID fail with error $TEST_EXITCODE"
        else
            TEST_EXITCODE=0
        fi
    fi
done
popd
echo "::endgroup::"
exit $TEST_EXITCODE
