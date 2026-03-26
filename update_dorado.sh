#!/bin/bash
set -e

# Ensure Conda environment is activated
if [[ -z "$CONDA_PREFIX" ]] || [[ "$CONDA_DEFAULT_ENV" == "base" ]]; then
	echo "Please activate your Conda environment first."
	exit 1
fi

#############################################################################################################################
################################################### CONSTRUCT THE DOWNLOAD LINK #############################################

# Set variables
INSTALL_DIR="$CONDA_PREFIX/opt/dorado"
BIN_DIR="$CONDA_PREFIX/bin"
RELEASE_API_URL="https://api.github.com/repos/nanoporetech/dorado/releases/latest"
# Base URL for CDN downloads - the version will be added dynamically
# Hope they don't change the link pattern in the future
# If they do, you can change the following line to the new link pattern
CDN_BASE_URL="https://cdn.oxfordnanoportal.com/software/analysis"
BINARY_SUFFIX="-linux-x64.tar.gz" # Suffix for the Linux x64 binary tarball

# Check if jq is installed
# It should be as we built the conda env from basecaller.yml file
echo -n "Checking for dependencies..."
if ! command -v jq &> /dev/null; then
	echo "ERROR"
	echo "jq is required but not installed. Please install jq (e.g., conda install jq)."
	exit 1
else echo "DONE"
fi

echo "Fetching latest stable Dorado release tag from GitHub API..."
LATEST_RELEASE=$(curl -s "$RELEASE_API_URL")

# Check if the release information was fetched
if [[ -z "$LATEST_RELEASE" ]]; then
	echo "Error: Could not fetch the latest release information from GitHub."
	exit 1
fi

# Check if the latest release is a pre-release
IS_PRERELEASE=$(echo "$LATEST_RELEASE" | jq -r ".prerelease")

# If it's a pre-release, notify the user and exit
# In future, can add a parameter specifying if a pre-release can be downloaded instead
# For now, we only look for latest stable release
if [ "$IS_PRERELEASE" == "true" ]; then
	echo "The latest release is a pre-release. This script is configured to only download stable releases."
	echo "If you need a pre-release, you will need to modify the script or specify a tag."
	exit 1
fi

# Extract the tag name (version) from the latest stable release
# Remove the leading 'v' if it exists
LATEST_TAG=$(echo "$LATEST_RELEASE" | jq -r ".tag_name | sub(\"^v\"; \"\")")

# Check if the tag name was extracted
if [[ -z "$LATEST_TAG" ]]; then
  echo "Error: Could not extract the latest release tag name from GitHub API response."
  exit 1
fi

# Construct the full download URL using the latest tag
BINARY_DOWNLOAD_URL="${CDN_BASE_URL}/dorado-${LATEST_TAG}${BINARY_SUFFIX}"

echo "Constructed download URL for latest version (${LATEST_TAG}): $BINARY_DOWNLOAD_URL"

# Determine the download filename from the URL
DOWNLOAD_FILENAME=$(basename "$BINARY_DOWNLOAD_URL")

# Download the binary tarball
echo "Downloading Dorado binary..."
curl -L -o "$DOWNLOAD_FILENAME" "$BINARY_DOWNLOAD_URL"

# Check if the download was successful
if [ ! -f "$DOWNLOAD_FILENAME" ]; then
	echo "Error: Download failed. The file '$DOWNLOAD_FILENAME' was not created."
	echo "Please verify the constructed URL and check if the binary exists at that location."
	exit
else
	echo "Download successful!"
fi

############################################ END DOWNLOAD ##############################################
########################################################################################################
############################### EXTRACTING AND BUILDING THE PACKAGE ####################################

# Extract the binary to the conda environment's opt directory
echo -n "Extracting Dorado to $INSTALL_DIR..."
mkdir -p "$INSTALL_DIR"
# Use tar's --strip-components to remove the top-level directory if present
# Assuming the tarball extracts into a directory like dorado-<version>-linux-x64/
tar -xzf "$DOWNLOAD_FILENAME" -C "$INSTALL_DIR" --strip-components 1
echo "DONE"
# Make the dorado an executable and create a symbolic link
# Normally, the executable is in a 'bin' subdirectory after extraction
if [ -f "$INSTALL_DIR/bin/dorado" ]; then
	echo -n "Making dorado executable..."
	chmod +x "$INSTALL_DIR/bin/dorado"
	# Create a symlink in the conda environment's bin directory
	mkdir -p "$BIN_DIR"
	ln -sf "$INSTALL_DIR/bin/dorado" "$BIN_DIR/dorado"
	echo "DONE"
	echo "Dorado installed successfully."
else
	echo "Error: Could not find the 'dorado' executable after extraction in $INSTALL_DIR/bin."
	echo "Please check the contents of $INSTALL_DIR after extraction."
	exit 1
fi

# Clean up the downloaded tarball
echo -n "Cleaning up downloaded file..."
rm "$DOWNLOAD_FILENAME"
echo "DONE"

# Get current version
echo "Test..."
dorado  --version
echo "Good basecalling!"

echo "You may need to deactivate and reactivate your environment for the modifications to take effect."
