set -e

ARCH=$1;
LLVM_VERSION=$2;

if [[ -z "${ACTIONS_RUNTIME_URL}" ]]; then
	echo "::error::ACTIONS_RUNTIME_URL is missing. Uploading artifacts won't work without it. See https://github.com/KOLANICH-GHActions/passthrough-restricted-actions-vars and https://github.com/KOLANICH-GHActions/node_based_cmd_action_template";
	exit 1;
fi;

if [[ -z "${ACTIONS_RUNTIME_TOKEN}" ]]; then
	echo "::error::ACTIONS_RUNTIME_TOKEN is missing. Uploading artifacts won't work without it. See https://github.com/KOLANICH-GHActions/passthrough-restricted-actions-vars and https://github.com/KOLANICH-GHActions/node_based_cmd_action_template";
	exit 1;
fi;

THIS_SCRIPT_DIR=`dirname "${BASH_SOURCE[0]}"`; # /home/runner/work/_actions/KOLANICH-GHActions/typical-python-workflow/master
echo "This script is $THIS_SCRIPT_DIR";
THIS_SCRIPT_DIR=`realpath "${THIS_SCRIPT_DIR}"`;
echo "This script is $THIS_SCRIPT_DIR";
ACTIONS_DIR=`realpath "$THIS_SCRIPT_DIR/../../.."`;

ISOLATE="${THIS_SCRIPT_DIR}/isolate.sh";
chmod +x $ISOLATE;

AUTHOR_NAMESPACE=KOLANICH-GHActions;

HARDENING_ACTION_REPO=$AUTHOR_NAMESPACE/hardening;
APT_ACTION_REPO=$AUTHOR_NAMESPACE/apt;
CHECKOUT_ACTION_REPO=$AUTHOR_NAMESPACE/checkout;

HARDENING_ACTION_DIR=$ACTIONS_DIR/$HARDENING_ACTION_REPO/master;
APT_ACTION_DIR=$ACTIONS_DIR/$APT_ACTION_REPO/master;
CHECKOUT_ACTION_DIR=$ACTIONS_DIR/$CHECKOUT_ACTION_REPO/master;

if [ -d "$HARDENING_ACTION_DIR" ]; then
	:
else
	git clone --depth=1 https://github.com/$HARDENING_ACTION_REPO $HARDENING_ACTION_DIR;
fi;

if [ -d "$CHECKOUT_ACTION_DIR" ]; then
	:
else
	$ISOLATE git clone --depth=1 https://github.com/$CHECKOUT_ACTION_REPO $CHECKOUT_ACTION_DIR;
fi;

if [ -d "$APT_ACTION_DIR" ]; then
	:
else
	$ISOLATE bash "$CHECKOUT_ACTION_DIR/action.sh" "$APT_ACTION_REPO" "" "$APT_ACTION_DIR" 1 0;
fi;

bash $HARDENING_ACTION_DIR/action.sh;

echo "##[group] add LLVM nightly repo"
eval `apt-config shell TRUSTED_KEYS_DIR Dir::Etc::TrustedParts/d`;
curl -L -o llvm-official-downloaded.gpg https://apt.llvm.org/llvm-snapshot.gpg.key;
sha512sum llvm-official-downloaded.gpg | grep 15a8b6bb63b14a7e64882edbc8a3425b95648624dacd08f965c60cffd69624e69c92193a694dce7f2a3c3ef977d8d1b394b6d9d06b3e10259d25f09d67baea87;
gpg --no-default-keyring --keyring ./kr.gpg --import ./llvm-official-downloaded.gpg;
gpg --no-default-keyring --keyring ./kr.gpg --export | sudo dd of=$TRUSTED_KEYS_DIR/llvm-official.gpg;
UBUNTU_RELEASE=`lsb_release -cs`;
echo "deb [signed-by=$TRUSTED_KEYS_DIR/llvm-official.gpg] https://apt.llvm.org/${UBUNTU_RELEASE}/ llvm-toolchain-${UBUNTU_RELEASE} main" | sudo dd of=/etc/apt/sources.list.d/llvm-official.list;
echo "##[endgroup]"

echo "##[group] update repos"
sudo apt-get update;
echo "##[endgroup]"

echo "##[group] install packages needed for building from Ubuntu repos"
sudo apt install ninja-build mingw-w64
echo "##[endgroup]"

echo "##[group] install latest LLVM + clang"
sudo apt-get install -y clang-$LLVM_VERSION clang++-$LLVM_VERSION llvm-$LLVM_VERSION lld-$LLVM_VERSION;
echo "##[endgroup]"


echo "Upgrade of setuptools and pip are needed because miniGHAPI has migrated to PEP 621"
echo "##[group] installing python3-build"
sudo apt-get install -y python3-build python3-httpx
echo "##[endgroup]"

echo "##[group] Upgrade setuptools"
git clone --depth=1 https://github.com/pypa/setuptools.git;
cd setuptools;
python3 -m build -nwx .
pip3 install --upgrade ./dist/*.whl
cd ..
rm -rf ./setuptools
echo "##[endgroup]"

echo "##[group] Upgrade pip"
git clone --depth=1 https://github.com/pypa/pip.git;
cd pip;
python3 -m build -nwx .
pip3 install --upgrade ./dist/*.whl
cd ..
rm -rf ./pip
echo "##[endgroup]"

echo "##[group] Install miniGHAPI.py"
pip3 install --upgrade git+https://github.com/KOLANICH-libs/miniGHAPI.py.git
echo "##[endgroup]"

echo "##[group] clone toolchain files"
git clone --depth=1 https://github.com/KOLANICH-libs/WindowsTargetToolchainFiles.cmake
echo "##[endgroup]"

$ISOLATE bash "$CHECKOUT_ACTION_DIR/action.sh" "$GITHUB_REPOSITORY" "$GITHUB_SHA" "$GITHUB_WORKSPACE" 1 1;

BEFORE_DEPS_COMMANDS_FILE="$GITHUB_WORKSPACE/.ci/beforeDeps.sh";
if [ -f "$BEFORE_DEPS_COMMANDS_FILE" ]; then
	echo "##[group] Running before deps commands";
	. $BEFORE_DEPS_COMMANDS_FILE ;
	echo "##[endgroup]";
fi;

echo "##[group] Installing dependencies";
bash $APT_ACTION_DIR/action.sh $GITHUB_WORKSPACE/.ci/aptPackagesToInstall.txt;
echo "##[endgroup]";

cd "$GITHUB_WORKSPACE";
mkdir ./build;
cd ./build;

echo "##[group] Configure CMake"
cmake .. -DCMAKE_BUILD_TYPE=RelWithDebInfo -DCMAKE_GENERATOR=Ninja --toolchain WindowsTargetToolchainFiles.cmake/${ARCH}_clang.cmake -DCMAKE_LINKER_FLAGS=-lssp -DCPACK_GENERATOR=7Z -DCPACK_OUTPUT_FILE_PREFIX=./built_packages
# -lssp is needed because it is not linked automatically in this version of Ubuntu
echo "##[endgroup]"

echo "##[group] Build"
ninja
echo "##[endgroup]"

echo "##[group] Package"
ninja package
echo "##[endgroup]"

echo "##[group] Uploading artifact"
python3 -m miniGHAPI artifact ./built_packages/*
echo "##[endgroup]"
