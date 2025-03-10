#!/bin/sh
                
# ---- this is added by cocoapods-binary ---
# Readlink cannot handle relative symlink well, so we override it to a new one
# If the path isn't an absolute path, we add a realtive prefix.
old_read_link=`which readlink`
readlink () {
    path=`$old_read_link "$1"`;
    if [ $(echo "$path" | cut -c 1-1) = '/' ]; then
        echo $path;
    else
        echo "`dirname $1`/$path";
    fi
}
# --- 
#!/bin/sh
set -e
set -u
set -o pipefail

function on_error {
  echo "$(realpath -mq "${0}"):$1: error: Unexpected failure"
}
trap 'on_error $LINENO' ERR

if [ -z ${FRAMEWORKS_FOLDER_PATH+x} ]; then
  # If FRAMEWORKS_FOLDER_PATH is not set, then there's nowhere for us to copy
  # frameworks to, so exit 0 (signalling the script phase was successful).
  exit 0
fi

echo "mkdir -p ${CONFIGURATION_BUILD_DIR}/${FRAMEWORKS_FOLDER_PATH}"
mkdir -p "${CONFIGURATION_BUILD_DIR}/${FRAMEWORKS_FOLDER_PATH}"

COCOAPODS_PARALLEL_CODE_SIGN="${COCOAPODS_PARALLEL_CODE_SIGN:-false}"
SWIFT_STDLIB_PATH="${DT_TOOLCHAIN_DIR}/usr/lib/swift/${PLATFORM_NAME}"

# Used as a return value for each invocation of `strip_invalid_archs` function.
STRIP_BINARY_RETVAL=0

# This protects against multiple targets copying the same framework dependency at the same time. The solution
# was originally proposed here: https://lists.samba.org/archive/rsync/2008-February/020158.html
RSYNC_PROTECT_TMP_FILES=(--filter "P .*.??????")

# Copies and strips a vendored framework
install_framework()
{
  if [ -r "${BUILT_PRODUCTS_DIR}/$1" ]; then
    local source="${BUILT_PRODUCTS_DIR}/$1"
  elif [ -r "${BUILT_PRODUCTS_DIR}/$(basename "$1")" ]; then
    local source="${BUILT_PRODUCTS_DIR}/$(basename "$1")"
  elif [ -r "$1" ]; then
    local source="$1"
  fi

  local destination="${TARGET_BUILD_DIR}/${FRAMEWORKS_FOLDER_PATH}"

  if [ -L "${source}" ]; then
    echo "Symlinked..."
    source="$(readlink "${source}")"
  fi

  # Use filter instead of exclude so missing patterns don't throw errors.
  echo "rsync --copy-links --delete -av "${RSYNC_PROTECT_TMP_FILES[@]}" --links --filter \"- CVS/\" --filter \"- .svn/\" --filter \"- .git/\" --filter \"- .hg/\" --filter \"- Headers\" --filter \"- PrivateHeaders\" --filter \"- Modules\" \"${source}\" \"${destination}\""
  rsync --copy-links --delete -av "${RSYNC_PROTECT_TMP_FILES[@]}" --links --filter "- CVS/" --filter "- .svn/" --filter "- .git/" --filter "- .hg/" --filter "- Headers" --filter "- PrivateHeaders" --filter "- Modules" "${source}" "${destination}"

  local basename
  basename="$(basename -s .framework "$1")"
  binary="${destination}/${basename}.framework/${basename}"

  if ! [ -r "$binary" ]; then
    binary="${destination}/${basename}"
  elif [ -L "${binary}" ]; then
    echo "Destination binary is symlinked..."
    dirname="$(dirname "${binary}")"
    binary="${dirname}/$(readlink "${binary}")"
  fi

  # Strip invalid architectures so "fat" simulator / device frameworks work on device
  if [[ "$(file "$binary")" == *"dynamically linked shared library"* ]]; then
    strip_invalid_archs "$binary"
  fi

  # Resign the code if required by the build settings to avoid unstable apps
  code_sign_if_enabled "${destination}/$(basename "$1")"

  # Embed linked Swift runtime libraries. No longer necessary as of Xcode 7.
  if [ "${XCODE_VERSION_MAJOR}" -lt 7 ]; then
    local swift_runtime_libs
    swift_runtime_libs=$(xcrun otool -LX "$binary" | grep --color=never @rpath/libswift | sed -E s/@rpath\\/\(.+dylib\).*/\\1/g | uniq -u)
    for lib in $swift_runtime_libs; do
      echo "rsync -auv \"${SWIFT_STDLIB_PATH}/${lib}\" \"${destination}\""
      rsync -auv "${SWIFT_STDLIB_PATH}/${lib}" "${destination}"
      code_sign_if_enabled "${destination}/${lib}"
    done
  fi
}

# Copies and strips a vendored dSYM
install_dsym() {
  local source="$1"
  warn_missing_arch=${2:-true}
  if [ -r "$source" ]; then
    # Copy the dSYM into the targets temp dir.
    echo "rsync --copy-links --delete -av "${RSYNC_PROTECT_TMP_FILES[@]}" --filter \"- CVS/\" --filter \"- .svn/\" --filter \"- .git/\" --filter \"- .hg/\" --filter \"- Headers\" --filter \"- PrivateHeaders\" --filter \"- Modules\" \"${source}\" \"${DERIVED_FILES_DIR}\""
    rsync --copy-links --delete -av "${RSYNC_PROTECT_TMP_FILES[@]}" --filter "- CVS/" --filter "- .svn/" --filter "- .git/" --filter "- .hg/" --filter "- Headers" --filter "- PrivateHeaders" --filter "- Modules" "${source}" "${DERIVED_FILES_DIR}"

    local basename
    basename="$(basename -s .dSYM "$source")"
    binary_name="$(ls "$source/Contents/Resources/DWARF")"
    binary="${DERIVED_FILES_DIR}/${basename}.dSYM/Contents/Resources/DWARF/${binary_name}"

    # Strip invalid architectures so "fat" simulator / device frameworks work on device
    if [[ "$(file "$binary")" == *"Mach-O "*"dSYM companion"* ]]; then
      strip_invalid_archs "$binary" "$warn_missing_arch"
    fi

    if [[ $STRIP_BINARY_RETVAL == 1 ]]; then
      # Move the stripped file into its final destination.
      echo "rsync --copy-links --delete -av "${RSYNC_PROTECT_TMP_FILES[@]}" --links --filter \"- CVS/\" --filter \"- .svn/\" --filter \"- .git/\" --filter \"- .hg/\" --filter \"- Headers\" --filter \"- PrivateHeaders\" --filter \"- Modules\" \"${DERIVED_FILES_DIR}/${basename}.framework.dSYM\" \"${DWARF_DSYM_FOLDER_PATH}\""
      rsync --copy-links --delete -av "${RSYNC_PROTECT_TMP_FILES[@]}" --links --filter "- CVS/" --filter "- .svn/" --filter "- .git/" --filter "- .hg/" --filter "- Headers" --filter "- PrivateHeaders" --filter "- Modules" "${DERIVED_FILES_DIR}/${basename}.dSYM" "${DWARF_DSYM_FOLDER_PATH}"
    else
      # The dSYM was not stripped at all, in this case touch a fake folder so the input/output paths from Xcode do not reexecute this script because the file is missing.
      touch "${DWARF_DSYM_FOLDER_PATH}/${basename}.dSYM"
    fi
  fi
}

# Copies the bcsymbolmap files of a vendored framework
install_bcsymbolmap() {
    local bcsymbolmap_path="$1"
    local destination="${BUILT_PRODUCTS_DIR}"
    echo "rsync --copy-links --delete -av "${RSYNC_PROTECT_TMP_FILES[@]}" --filter "- CVS/" --filter "- .svn/" --filter "- .git/" --filter "- .hg/" --filter "- Headers" --filter "- PrivateHeaders" --filter "- Modules" "${bcsymbolmap_path}" "${destination}""
    rsync --copy-links --delete -av "${RSYNC_PROTECT_TMP_FILES[@]}" --filter "- CVS/" --filter "- .svn/" --filter "- .git/" --filter "- .hg/" --filter "- Headers" --filter "- PrivateHeaders" --filter "- Modules" "${bcsymbolmap_path}" "${destination}"
}

# Signs a framework with the provided identity
code_sign_if_enabled() {
  if [ -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" -a "${CODE_SIGNING_REQUIRED:-}" != "NO" -a "${CODE_SIGNING_ALLOWED}" != "NO" ]; then
    # Use the current code_sign_identity
    echo "Code Signing $1 with Identity ${EXPANDED_CODE_SIGN_IDENTITY_NAME}"
    local code_sign_cmd="/usr/bin/codesign --force --sign ${EXPANDED_CODE_SIGN_IDENTITY} ${OTHER_CODE_SIGN_FLAGS:-} --preserve-metadata=identifier,entitlements '$1'"

    if [ "${COCOAPODS_PARALLEL_CODE_SIGN}" == "true" ]; then
      code_sign_cmd="$code_sign_cmd &"
    fi
    echo "$code_sign_cmd"
    eval "$code_sign_cmd"
  fi
}

# Strip invalid architectures
strip_invalid_archs() {
  binary="$1"
  warn_missing_arch=${2:-true}
  # Get architectures for current target binary
  binary_archs="$(lipo -info "$binary" | rev | cut -d ':' -f1 | awk '{$1=$1;print}' | rev)"
  # Intersect them with the architectures we are building for
  intersected_archs="$(echo ${ARCHS[@]} ${binary_archs[@]} | tr ' ' '\n' | sort | uniq -d)"
  # If there are no archs supported by this binary then warn the user
  if [[ -z "$intersected_archs" ]]; then
    if [[ "$warn_missing_arch" == "true" ]]; then
      echo "warning: [CP] Vendored binary '$binary' contains architectures ($binary_archs) none of which match the current build architectures ($ARCHS)."
    fi
    STRIP_BINARY_RETVAL=0
    return
  fi
  stripped=""
  for arch in $binary_archs; do
    if ! [[ "${ARCHS}" == *"$arch"* ]]; then
      # Strip non-valid architectures in-place
      lipo -remove "$arch" -output "$binary" "$binary"
      stripped="$stripped $arch"
    fi
  done
  if [[ "$stripped" ]]; then
    echo "Stripped $binary of architectures:$stripped"
  fi
  STRIP_BINARY_RETVAL=1
}

install_artifact() {
  artifact="$1"
  base="$(basename "$artifact")"
  case $base in
  *.framework)
    install_framework "$artifact"
    ;;
  *.dSYM)
    # Suppress arch warnings since XCFrameworks will include many dSYM files
    install_dsym "$artifact" "false"
    ;;
  *.bcsymbolmap)
    install_bcsymbolmap "$artifact"
    ;;
  *)
    echo "error: Unrecognized artifact "$artifact""
    ;;
  esac
}

copy_artifacts() {
  file_list="$1"
  while read artifact; do
    install_artifact "$artifact"
  done <$file_list
}

ARTIFACT_LIST_FILE="${BUILT_PRODUCTS_DIR}/cocoapods-artifacts-${CONFIGURATION}.txt"
if [ -r "${ARTIFACT_LIST_FILE}" ]; then
  copy_artifacts "${ARTIFACT_LIST_FILE}"
fi

if [[ "$CONFIGURATION" == "Debug" ]]; then
  install_framework "${BUILT_PRODUCTS_DIR}/AFNetworking/AFNetworking.framework"
  install_framework "${BUILT_PRODUCTS_DIR}/BonMot/BonMot.framework"
  install_framework "${BUILT_PRODUCTS_DIR}/CGRPCZlib/CGRPCZlib.framework"
  install_framework "${BUILT_PRODUCTS_DIR}/CNIOAtomics/CNIOAtomics.framework"
  install_framework "${BUILT_PRODUCTS_DIR}/CNIOBoringSSL/CNIOBoringSSL.framework"
  install_framework "${BUILT_PRODUCTS_DIR}/CNIOBoringSSLShims/CNIOBoringSSLShims.framework"
  install_framework "${BUILT_PRODUCTS_DIR}/CNIODarwin/CNIODarwin.framework"
  install_framework "${BUILT_PRODUCTS_DIR}/CNIOHTTPParser/CNIOHTTPParser.framework"
  install_framework "${BUILT_PRODUCTS_DIR}/CNIOLinux/CNIOLinux.framework"
  install_framework "${BUILT_PRODUCTS_DIR}/CNIOWindows/CNIOWindows.framework"
  install_framework "${BUILT_PRODUCTS_DIR}/CocoaLumberjack/CocoaLumberjack.framework"
  install_framework "${BUILT_PRODUCTS_DIR}/Curve25519Kit/Curve25519Kit.framework"
  install_framework "${BUILT_PRODUCTS_DIR}/GRDB.swift/GRDB.framework"
  install_framework "${PODS_ROOT}/GRKOpenSSLFramework/OpenSSL-iOS/bin/openssl.framework"
  install_framework "${BUILT_PRODUCTS_DIR}/LibMobileCoin/LibMobileCoin.framework"
  install_framework "${BUILT_PRODUCTS_DIR}/Logging/Logging.framework"
  install_framework "${BUILT_PRODUCTS_DIR}/Mantle/Mantle.framework"
  install_framework "${BUILT_PRODUCTS_DIR}/MobileCoin/MobileCoin.framework"
  install_framework "${BUILT_PRODUCTS_DIR}/PromiseKit/PromiseKit.framework"
  install_framework "${BUILT_PRODUCTS_DIR}/PureLayout/PureLayout.framework"
  install_framework "${BUILT_PRODUCTS_DIR}/Reachability/Reachability.framework"
  install_framework "${BUILT_PRODUCTS_DIR}/SAMKeychain/SAMKeychain.framework"
  install_framework "${BUILT_PRODUCTS_DIR}/SQLCipher/SQLCipher.framework"
  install_framework "${BUILT_PRODUCTS_DIR}/SignalArgon2/SignalArgon2.framework"
  install_framework "${BUILT_PRODUCTS_DIR}/SignalClient/SignalClient.framework"
  install_framework "${BUILT_PRODUCTS_DIR}/SignalCoreKit/SignalCoreKit.framework"
  install_framework "${BUILT_PRODUCTS_DIR}/SignalMetadataKit/SignalMetadataKit.framework"
  install_framework "${BUILT_PRODUCTS_DIR}/SignalServiceKit/SignalServiceKit.framework"
  install_framework "${BUILT_PRODUCTS_DIR}/Starscream/Starscream.framework"
  install_framework "${BUILT_PRODUCTS_DIR}/SwiftNIO/NIO.framework"
  install_framework "${BUILT_PRODUCTS_DIR}/SwiftNIOConcurrencyHelpers/NIOConcurrencyHelpers.framework"
  install_framework "${BUILT_PRODUCTS_DIR}/SwiftNIOExtras/NIOExtras.framework"
  install_framework "${BUILT_PRODUCTS_DIR}/SwiftNIOFoundationCompat/NIOFoundationCompat.framework"
  install_framework "${BUILT_PRODUCTS_DIR}/SwiftNIOHPACK/NIOHPACK.framework"
  install_framework "${BUILT_PRODUCTS_DIR}/SwiftNIOHTTP1/NIOHTTP1.framework"
  install_framework "${BUILT_PRODUCTS_DIR}/SwiftNIOHTTP2/NIOHTTP2.framework"
  install_framework "${BUILT_PRODUCTS_DIR}/SwiftNIOSSL/NIOSSL.framework"
  install_framework "${BUILT_PRODUCTS_DIR}/SwiftNIOTLS/NIOTLS.framework"
  install_framework "${BUILT_PRODUCTS_DIR}/SwiftNIOTransportServices/NIOTransportServices.framework"
  install_framework "${BUILT_PRODUCTS_DIR}/SwiftProtobuf/SwiftProtobuf.framework"
  install_framework "${BUILT_PRODUCTS_DIR}/YYImage/YYImage.framework"
  install_framework "${BUILT_PRODUCTS_DIR}/ZKGroup/ZKGroup.framework"
  install_framework "${PODS_ROOT}/ZXingObjC/ZXingObjC.framework"
  install_dsym "${PODS_ROOT}/ZXingObjC/ZXingObjC.framework.dSYM"
  install_framework "${BUILT_PRODUCTS_DIR}/blurhash/blurhash.framework"
  install_framework "${BUILT_PRODUCTS_DIR}/gRPC-Swift/GRPC.framework"
  install_framework "${BUILT_PRODUCTS_DIR}/libPhoneNumber-iOS/libPhoneNumber_iOS.framework"
  install_framework "${BUILT_PRODUCTS_DIR}/libwebp/libwebp.framework"
  install_framework "${BUILT_PRODUCTS_DIR}/lottie-ios/Lottie.framework"
  install_framework "${BUILT_PRODUCTS_DIR}/SSZipArchive/SSZipArchive.framework"
  install_framework "${BUILT_PRODUCTS_DIR}/SignalRingRTC/SignalRingRTC.framework"
  install_framework "${PODS_ROOT}/../ThirdParty/WebRTC/Build/WebRTC.framework"
fi
if [[ "$CONFIGURATION" == "App Store Release" ]]; then
  install_framework "${BUILT_PRODUCTS_DIR}/AFNetworking/AFNetworking.framework"
  install_framework "${BUILT_PRODUCTS_DIR}/BonMot/BonMot.framework"
  install_framework "${BUILT_PRODUCTS_DIR}/CGRPCZlib/CGRPCZlib.framework"
  install_framework "${BUILT_PRODUCTS_DIR}/CNIOAtomics/CNIOAtomics.framework"
  install_framework "${BUILT_PRODUCTS_DIR}/CNIOBoringSSL/CNIOBoringSSL.framework"
  install_framework "${BUILT_PRODUCTS_DIR}/CNIOBoringSSLShims/CNIOBoringSSLShims.framework"
  install_framework "${BUILT_PRODUCTS_DIR}/CNIODarwin/CNIODarwin.framework"
  install_framework "${BUILT_PRODUCTS_DIR}/CNIOHTTPParser/CNIOHTTPParser.framework"
  install_framework "${BUILT_PRODUCTS_DIR}/CNIOLinux/CNIOLinux.framework"
  install_framework "${BUILT_PRODUCTS_DIR}/CNIOWindows/CNIOWindows.framework"
  install_framework "${BUILT_PRODUCTS_DIR}/CocoaLumberjack/CocoaLumberjack.framework"
  install_framework "${BUILT_PRODUCTS_DIR}/Curve25519Kit/Curve25519Kit.framework"
  install_framework "${BUILT_PRODUCTS_DIR}/GRDB.swift/GRDB.framework"
  install_framework "${PODS_ROOT}/GRKOpenSSLFramework/OpenSSL-iOS/bin/openssl.framework"
  install_framework "${BUILT_PRODUCTS_DIR}/LibMobileCoin/LibMobileCoin.framework"
  install_framework "${BUILT_PRODUCTS_DIR}/Logging/Logging.framework"
  install_framework "${BUILT_PRODUCTS_DIR}/Mantle/Mantle.framework"
  install_framework "${BUILT_PRODUCTS_DIR}/MobileCoin/MobileCoin.framework"
  install_framework "${BUILT_PRODUCTS_DIR}/PromiseKit/PromiseKit.framework"
  install_framework "${BUILT_PRODUCTS_DIR}/PureLayout/PureLayout.framework"
  install_framework "${BUILT_PRODUCTS_DIR}/Reachability/Reachability.framework"
  install_framework "${BUILT_PRODUCTS_DIR}/SAMKeychain/SAMKeychain.framework"
  install_framework "${BUILT_PRODUCTS_DIR}/SQLCipher/SQLCipher.framework"
  install_framework "${BUILT_PRODUCTS_DIR}/SignalArgon2/SignalArgon2.framework"
  install_framework "${BUILT_PRODUCTS_DIR}/SignalClient/SignalClient.framework"
  install_framework "${BUILT_PRODUCTS_DIR}/SignalCoreKit/SignalCoreKit.framework"
  install_framework "${BUILT_PRODUCTS_DIR}/SignalMetadataKit/SignalMetadataKit.framework"
  install_framework "${BUILT_PRODUCTS_DIR}/SignalServiceKit/SignalServiceKit.framework"
  install_framework "${BUILT_PRODUCTS_DIR}/Starscream/Starscream.framework"
  install_framework "${BUILT_PRODUCTS_DIR}/SwiftNIO/NIO.framework"
  install_framework "${BUILT_PRODUCTS_DIR}/SwiftNIOConcurrencyHelpers/NIOConcurrencyHelpers.framework"
  install_framework "${BUILT_PRODUCTS_DIR}/SwiftNIOExtras/NIOExtras.framework"
  install_framework "${BUILT_PRODUCTS_DIR}/SwiftNIOFoundationCompat/NIOFoundationCompat.framework"
  install_framework "${BUILT_PRODUCTS_DIR}/SwiftNIOHPACK/NIOHPACK.framework"
  install_framework "${BUILT_PRODUCTS_DIR}/SwiftNIOHTTP1/NIOHTTP1.framework"
  install_framework "${BUILT_PRODUCTS_DIR}/SwiftNIOHTTP2/NIOHTTP2.framework"
  install_framework "${BUILT_PRODUCTS_DIR}/SwiftNIOSSL/NIOSSL.framework"
  install_framework "${BUILT_PRODUCTS_DIR}/SwiftNIOTLS/NIOTLS.framework"
  install_framework "${BUILT_PRODUCTS_DIR}/SwiftNIOTransportServices/NIOTransportServices.framework"
  install_framework "${BUILT_PRODUCTS_DIR}/SwiftProtobuf/SwiftProtobuf.framework"
  install_framework "${BUILT_PRODUCTS_DIR}/YYImage/YYImage.framework"
  install_framework "${BUILT_PRODUCTS_DIR}/ZKGroup/ZKGroup.framework"
  install_framework "${PODS_ROOT}/ZXingObjC/ZXingObjC.framework"
  install_dsym "${PODS_ROOT}/ZXingObjC/ZXingObjC.framework.dSYM"
  install_framework "${BUILT_PRODUCTS_DIR}/blurhash/blurhash.framework"
  install_framework "${BUILT_PRODUCTS_DIR}/gRPC-Swift/GRPC.framework"
  install_framework "${BUILT_PRODUCTS_DIR}/libPhoneNumber-iOS/libPhoneNumber_iOS.framework"
  install_framework "${BUILT_PRODUCTS_DIR}/libwebp/libwebp.framework"
  install_framework "${BUILT_PRODUCTS_DIR}/lottie-ios/Lottie.framework"
  install_framework "${BUILT_PRODUCTS_DIR}/SSZipArchive/SSZipArchive.framework"
  install_framework "${BUILT_PRODUCTS_DIR}/SignalRingRTC/SignalRingRTC.framework"
  install_framework "${PODS_ROOT}/../ThirdParty/WebRTC/Build/WebRTC.framework"
fi
if [[ "$CONFIGURATION" == "Profiling" ]]; then
  install_framework "${BUILT_PRODUCTS_DIR}/AFNetworking/AFNetworking.framework"
  install_framework "${BUILT_PRODUCTS_DIR}/BonMot/BonMot.framework"
  install_framework "${BUILT_PRODUCTS_DIR}/CGRPCZlib/CGRPCZlib.framework"
  install_framework "${BUILT_PRODUCTS_DIR}/CNIOAtomics/CNIOAtomics.framework"
  install_framework "${BUILT_PRODUCTS_DIR}/CNIOBoringSSL/CNIOBoringSSL.framework"
  install_framework "${BUILT_PRODUCTS_DIR}/CNIOBoringSSLShims/CNIOBoringSSLShims.framework"
  install_framework "${BUILT_PRODUCTS_DIR}/CNIODarwin/CNIODarwin.framework"
  install_framework "${BUILT_PRODUCTS_DIR}/CNIOHTTPParser/CNIOHTTPParser.framework"
  install_framework "${BUILT_PRODUCTS_DIR}/CNIOLinux/CNIOLinux.framework"
  install_framework "${BUILT_PRODUCTS_DIR}/CNIOWindows/CNIOWindows.framework"
  install_framework "${BUILT_PRODUCTS_DIR}/CocoaLumberjack/CocoaLumberjack.framework"
  install_framework "${BUILT_PRODUCTS_DIR}/Curve25519Kit/Curve25519Kit.framework"
  install_framework "${BUILT_PRODUCTS_DIR}/GRDB.swift/GRDB.framework"
  install_framework "${PODS_ROOT}/GRKOpenSSLFramework/OpenSSL-iOS/bin/openssl.framework"
  install_framework "${BUILT_PRODUCTS_DIR}/LibMobileCoin/LibMobileCoin.framework"
  install_framework "${BUILT_PRODUCTS_DIR}/Logging/Logging.framework"
  install_framework "${BUILT_PRODUCTS_DIR}/Mantle/Mantle.framework"
  install_framework "${BUILT_PRODUCTS_DIR}/MobileCoin/MobileCoin.framework"
  install_framework "${BUILT_PRODUCTS_DIR}/PromiseKit/PromiseKit.framework"
  install_framework "${BUILT_PRODUCTS_DIR}/PureLayout/PureLayout.framework"
  install_framework "${BUILT_PRODUCTS_DIR}/Reachability/Reachability.framework"
  install_framework "${BUILT_PRODUCTS_DIR}/SAMKeychain/SAMKeychain.framework"
  install_framework "${BUILT_PRODUCTS_DIR}/SQLCipher/SQLCipher.framework"
  install_framework "${BUILT_PRODUCTS_DIR}/SignalArgon2/SignalArgon2.framework"
  install_framework "${BUILT_PRODUCTS_DIR}/SignalClient/SignalClient.framework"
  install_framework "${BUILT_PRODUCTS_DIR}/SignalCoreKit/SignalCoreKit.framework"
  install_framework "${BUILT_PRODUCTS_DIR}/SignalMetadataKit/SignalMetadataKit.framework"
  install_framework "${BUILT_PRODUCTS_DIR}/SignalServiceKit/SignalServiceKit.framework"
  install_framework "${BUILT_PRODUCTS_DIR}/Starscream/Starscream.framework"
  install_framework "${BUILT_PRODUCTS_DIR}/SwiftNIO/NIO.framework"
  install_framework "${BUILT_PRODUCTS_DIR}/SwiftNIOConcurrencyHelpers/NIOConcurrencyHelpers.framework"
  install_framework "${BUILT_PRODUCTS_DIR}/SwiftNIOExtras/NIOExtras.framework"
  install_framework "${BUILT_PRODUCTS_DIR}/SwiftNIOFoundationCompat/NIOFoundationCompat.framework"
  install_framework "${BUILT_PRODUCTS_DIR}/SwiftNIOHPACK/NIOHPACK.framework"
  install_framework "${BUILT_PRODUCTS_DIR}/SwiftNIOHTTP1/NIOHTTP1.framework"
  install_framework "${BUILT_PRODUCTS_DIR}/SwiftNIOHTTP2/NIOHTTP2.framework"
  install_framework "${BUILT_PRODUCTS_DIR}/SwiftNIOSSL/NIOSSL.framework"
  install_framework "${BUILT_PRODUCTS_DIR}/SwiftNIOTLS/NIOTLS.framework"
  install_framework "${BUILT_PRODUCTS_DIR}/SwiftNIOTransportServices/NIOTransportServices.framework"
  install_framework "${BUILT_PRODUCTS_DIR}/SwiftProtobuf/SwiftProtobuf.framework"
  install_framework "${BUILT_PRODUCTS_DIR}/YYImage/YYImage.framework"
  install_framework "${BUILT_PRODUCTS_DIR}/ZKGroup/ZKGroup.framework"
  install_framework "${PODS_ROOT}/ZXingObjC/ZXingObjC.framework"
  install_dsym "${PODS_ROOT}/ZXingObjC/ZXingObjC.framework.dSYM"
  install_framework "${BUILT_PRODUCTS_DIR}/blurhash/blurhash.framework"
  install_framework "${BUILT_PRODUCTS_DIR}/gRPC-Swift/GRPC.framework"
  install_framework "${BUILT_PRODUCTS_DIR}/libPhoneNumber-iOS/libPhoneNumber_iOS.framework"
  install_framework "${BUILT_PRODUCTS_DIR}/libwebp/libwebp.framework"
  install_framework "${BUILT_PRODUCTS_DIR}/lottie-ios/Lottie.framework"
  install_framework "${BUILT_PRODUCTS_DIR}/SSZipArchive/SSZipArchive.framework"
  install_framework "${BUILT_PRODUCTS_DIR}/SignalRingRTC/SignalRingRTC.framework"
  install_framework "${PODS_ROOT}/../ThirdParty/WebRTC/Build/WebRTC.framework"
fi
if [[ "$CONFIGURATION" == "Testable Release" ]]; then
  install_framework "${BUILT_PRODUCTS_DIR}/AFNetworking/AFNetworking.framework"
  install_framework "${BUILT_PRODUCTS_DIR}/BonMot/BonMot.framework"
  install_framework "${BUILT_PRODUCTS_DIR}/CGRPCZlib/CGRPCZlib.framework"
  install_framework "${BUILT_PRODUCTS_DIR}/CNIOAtomics/CNIOAtomics.framework"
  install_framework "${BUILT_PRODUCTS_DIR}/CNIOBoringSSL/CNIOBoringSSL.framework"
  install_framework "${BUILT_PRODUCTS_DIR}/CNIOBoringSSLShims/CNIOBoringSSLShims.framework"
  install_framework "${BUILT_PRODUCTS_DIR}/CNIODarwin/CNIODarwin.framework"
  install_framework "${BUILT_PRODUCTS_DIR}/CNIOHTTPParser/CNIOHTTPParser.framework"
  install_framework "${BUILT_PRODUCTS_DIR}/CNIOLinux/CNIOLinux.framework"
  install_framework "${BUILT_PRODUCTS_DIR}/CNIOWindows/CNIOWindows.framework"
  install_framework "${BUILT_PRODUCTS_DIR}/CocoaLumberjack/CocoaLumberjack.framework"
  install_framework "${BUILT_PRODUCTS_DIR}/Curve25519Kit/Curve25519Kit.framework"
  install_framework "${BUILT_PRODUCTS_DIR}/GRDB.swift/GRDB.framework"
  install_framework "${PODS_ROOT}/GRKOpenSSLFramework/OpenSSL-iOS/bin/openssl.framework"
  install_framework "${BUILT_PRODUCTS_DIR}/LibMobileCoin/LibMobileCoin.framework"
  install_framework "${BUILT_PRODUCTS_DIR}/Logging/Logging.framework"
  install_framework "${BUILT_PRODUCTS_DIR}/Mantle/Mantle.framework"
  install_framework "${BUILT_PRODUCTS_DIR}/MobileCoin/MobileCoin.framework"
  install_framework "${BUILT_PRODUCTS_DIR}/PromiseKit/PromiseKit.framework"
  install_framework "${BUILT_PRODUCTS_DIR}/PureLayout/PureLayout.framework"
  install_framework "${BUILT_PRODUCTS_DIR}/Reachability/Reachability.framework"
  install_framework "${BUILT_PRODUCTS_DIR}/SAMKeychain/SAMKeychain.framework"
  install_framework "${BUILT_PRODUCTS_DIR}/SQLCipher/SQLCipher.framework"
  install_framework "${BUILT_PRODUCTS_DIR}/SignalArgon2/SignalArgon2.framework"
  install_framework "${BUILT_PRODUCTS_DIR}/SignalClient/SignalClient.framework"
  install_framework "${BUILT_PRODUCTS_DIR}/SignalCoreKit/SignalCoreKit.framework"
  install_framework "${BUILT_PRODUCTS_DIR}/SignalMetadataKit/SignalMetadataKit.framework"
  install_framework "${BUILT_PRODUCTS_DIR}/SignalServiceKit/SignalServiceKit.framework"
  install_framework "${BUILT_PRODUCTS_DIR}/Starscream/Starscream.framework"
  install_framework "${BUILT_PRODUCTS_DIR}/SwiftNIO/NIO.framework"
  install_framework "${BUILT_PRODUCTS_DIR}/SwiftNIOConcurrencyHelpers/NIOConcurrencyHelpers.framework"
  install_framework "${BUILT_PRODUCTS_DIR}/SwiftNIOExtras/NIOExtras.framework"
  install_framework "${BUILT_PRODUCTS_DIR}/SwiftNIOFoundationCompat/NIOFoundationCompat.framework"
  install_framework "${BUILT_PRODUCTS_DIR}/SwiftNIOHPACK/NIOHPACK.framework"
  install_framework "${BUILT_PRODUCTS_DIR}/SwiftNIOHTTP1/NIOHTTP1.framework"
  install_framework "${BUILT_PRODUCTS_DIR}/SwiftNIOHTTP2/NIOHTTP2.framework"
  install_framework "${BUILT_PRODUCTS_DIR}/SwiftNIOSSL/NIOSSL.framework"
  install_framework "${BUILT_PRODUCTS_DIR}/SwiftNIOTLS/NIOTLS.framework"
  install_framework "${BUILT_PRODUCTS_DIR}/SwiftNIOTransportServices/NIOTransportServices.framework"
  install_framework "${BUILT_PRODUCTS_DIR}/SwiftProtobuf/SwiftProtobuf.framework"
  install_framework "${BUILT_PRODUCTS_DIR}/YYImage/YYImage.framework"
  install_framework "${BUILT_PRODUCTS_DIR}/ZKGroup/ZKGroup.framework"
  install_framework "${PODS_ROOT}/ZXingObjC/ZXingObjC.framework"
  install_dsym "${PODS_ROOT}/ZXingObjC/ZXingObjC.framework.dSYM"
  install_framework "${BUILT_PRODUCTS_DIR}/blurhash/blurhash.framework"
  install_framework "${BUILT_PRODUCTS_DIR}/gRPC-Swift/GRPC.framework"
  install_framework "${BUILT_PRODUCTS_DIR}/libPhoneNumber-iOS/libPhoneNumber_iOS.framework"
  install_framework "${BUILT_PRODUCTS_DIR}/libwebp/libwebp.framework"
  install_framework "${BUILT_PRODUCTS_DIR}/lottie-ios/Lottie.framework"
  install_framework "${BUILT_PRODUCTS_DIR}/SSZipArchive/SSZipArchive.framework"
  install_framework "${BUILT_PRODUCTS_DIR}/SignalRingRTC/SignalRingRTC.framework"
  install_framework "${PODS_ROOT}/../ThirdParty/WebRTC/Build/WebRTC.framework"
fi
if [[ "$CONFIGURATION" == "Release" ]]; then
  install_framework "${BUILT_PRODUCTS_DIR}/AFNetworking/AFNetworking.framework"
  install_framework "${BUILT_PRODUCTS_DIR}/BonMot/BonMot.framework"
  install_framework "${BUILT_PRODUCTS_DIR}/CGRPCZlib/CGRPCZlib.framework"
  install_framework "${BUILT_PRODUCTS_DIR}/CNIOAtomics/CNIOAtomics.framework"
  install_framework "${BUILT_PRODUCTS_DIR}/CNIOBoringSSL/CNIOBoringSSL.framework"
  install_framework "${BUILT_PRODUCTS_DIR}/CNIOBoringSSLShims/CNIOBoringSSLShims.framework"
  install_framework "${BUILT_PRODUCTS_DIR}/CNIODarwin/CNIODarwin.framework"
  install_framework "${BUILT_PRODUCTS_DIR}/CNIOHTTPParser/CNIOHTTPParser.framework"
  install_framework "${BUILT_PRODUCTS_DIR}/CNIOLinux/CNIOLinux.framework"
  install_framework "${BUILT_PRODUCTS_DIR}/CNIOWindows/CNIOWindows.framework"
  install_framework "${BUILT_PRODUCTS_DIR}/CocoaLumberjack/CocoaLumberjack.framework"
  install_framework "${BUILT_PRODUCTS_DIR}/Curve25519Kit/Curve25519Kit.framework"
  install_framework "${BUILT_PRODUCTS_DIR}/GRDB.swift/GRDB.framework"
  install_framework "${PODS_ROOT}/GRKOpenSSLFramework/OpenSSL-iOS/bin/openssl.framework"
  install_framework "${BUILT_PRODUCTS_DIR}/LibMobileCoin/LibMobileCoin.framework"
  install_framework "${BUILT_PRODUCTS_DIR}/Logging/Logging.framework"
  install_framework "${BUILT_PRODUCTS_DIR}/Mantle/Mantle.framework"
  install_framework "${BUILT_PRODUCTS_DIR}/MobileCoin/MobileCoin.framework"
  install_framework "${BUILT_PRODUCTS_DIR}/PromiseKit/PromiseKit.framework"
  install_framework "${BUILT_PRODUCTS_DIR}/PureLayout/PureLayout.framework"
  install_framework "${BUILT_PRODUCTS_DIR}/Reachability/Reachability.framework"
  install_framework "${BUILT_PRODUCTS_DIR}/SAMKeychain/SAMKeychain.framework"
  install_framework "${BUILT_PRODUCTS_DIR}/SQLCipher/SQLCipher.framework"
  install_framework "${BUILT_PRODUCTS_DIR}/SignalArgon2/SignalArgon2.framework"
  install_framework "${BUILT_PRODUCTS_DIR}/SignalClient/SignalClient.framework"
  install_framework "${BUILT_PRODUCTS_DIR}/SignalCoreKit/SignalCoreKit.framework"
  install_framework "${BUILT_PRODUCTS_DIR}/SignalMetadataKit/SignalMetadataKit.framework"
  install_framework "${BUILT_PRODUCTS_DIR}/SignalServiceKit/SignalServiceKit.framework"
  install_framework "${BUILT_PRODUCTS_DIR}/Starscream/Starscream.framework"
  install_framework "${BUILT_PRODUCTS_DIR}/SwiftNIO/NIO.framework"
  install_framework "${BUILT_PRODUCTS_DIR}/SwiftNIOConcurrencyHelpers/NIOConcurrencyHelpers.framework"
  install_framework "${BUILT_PRODUCTS_DIR}/SwiftNIOExtras/NIOExtras.framework"
  install_framework "${BUILT_PRODUCTS_DIR}/SwiftNIOFoundationCompat/NIOFoundationCompat.framework"
  install_framework "${BUILT_PRODUCTS_DIR}/SwiftNIOHPACK/NIOHPACK.framework"
  install_framework "${BUILT_PRODUCTS_DIR}/SwiftNIOHTTP1/NIOHTTP1.framework"
  install_framework "${BUILT_PRODUCTS_DIR}/SwiftNIOHTTP2/NIOHTTP2.framework"
  install_framework "${BUILT_PRODUCTS_DIR}/SwiftNIOSSL/NIOSSL.framework"
  install_framework "${BUILT_PRODUCTS_DIR}/SwiftNIOTLS/NIOTLS.framework"
  install_framework "${BUILT_PRODUCTS_DIR}/SwiftNIOTransportServices/NIOTransportServices.framework"
  install_framework "${BUILT_PRODUCTS_DIR}/SwiftProtobuf/SwiftProtobuf.framework"
  install_framework "${BUILT_PRODUCTS_DIR}/YYImage/YYImage.framework"
  install_framework "${BUILT_PRODUCTS_DIR}/ZKGroup/ZKGroup.framework"
  install_framework "${PODS_ROOT}/ZXingObjC/ZXingObjC.framework"
  install_dsym "${PODS_ROOT}/ZXingObjC/ZXingObjC.framework.dSYM"
  install_framework "${BUILT_PRODUCTS_DIR}/blurhash/blurhash.framework"
  install_framework "${BUILT_PRODUCTS_DIR}/gRPC-Swift/GRPC.framework"
  install_framework "${BUILT_PRODUCTS_DIR}/libPhoneNumber-iOS/libPhoneNumber_iOS.framework"
  install_framework "${BUILT_PRODUCTS_DIR}/libwebp/libwebp.framework"
  install_framework "${BUILT_PRODUCTS_DIR}/lottie-ios/Lottie.framework"
  install_framework "${BUILT_PRODUCTS_DIR}/SSZipArchive/SSZipArchive.framework"
  install_framework "${BUILT_PRODUCTS_DIR}/SignalRingRTC/SignalRingRTC.framework"
  install_framework "${PODS_ROOT}/../ThirdParty/WebRTC/Build/WebRTC.framework"
fi
if [ "${COCOAPODS_PARALLEL_CODE_SIGN}" == "true" ]; then
  wait
fi
