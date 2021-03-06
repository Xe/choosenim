import httpclient, os, strutils, osproc, sequtils, times, uri

import nimblepkg/[cli, tools, version]
import untar

import switcher, cliparams, common

proc parseVersion*(versionStr: string): Version =
  if versionStr[0] notin {'#', '\0'} + Digits:
    let msg = "Invalid version, path or unknown channel. " &
              "Try 0.16.0, #head, #commitHash, or stable. " &
              "See --help for more examples."
    raise newException(ChooseNimError, msg)

  let parts = versionStr.split(".")
  if parts.len >= 3 and parts[2].parseInt() mod 2 != 0:
    let msg = ("Version $# is a development version of Nim. This means " &
              "it hasn't been released so you cannot install it this " &
              "way. All unreleased versions of Nim " &
              "have an odd patch number in their version.") % versionStr
    let exc = newException(ChooseNimError, msg)
    exc.hint = "If you want to install the development version then run " &
               "`choosenim devel`."
    raise exc

  result = newVersion(versionStr)

proc doCmdRaw*(cmd: string) =
  # To keep output in sequence
  stdout.flushFile()
  stderr.flushFile()

  displayDebug("Executing", cmd)
  let (output, exitCode) = execCmdEx(cmd)
  displayDebug("Finished", "with exit code " & $exitCode)
  displayDebug("Output", output)

  if exitCode != QuitSuccess:
    raise newException(ChooseNimError,
        "Execution failed with exit code $1\nCommand: $2\nOutput: $3" %
        [$exitCode, cmd, output])

proc extractZip(path: string, extractDir: string, skipOuterDirs = true, tempDir: string = "") =
  var tempDir = tempDir
  if tempDir.len == 0:
    tempDir = getTempDir() / "choosenim-" & $getTime().toUnix()
  removeDir(tempDir)
  createDir(tempDir)

  var cmd = "unzip -o $1 -d $2"
  if defined(windows):
    cmd = "powershell -nologo -noprofile -command \"& { Add-Type -A 'System.IO.Compression.FileSystem'; [IO.Compression.ZipFile]::ExtractToDirectory('$1', '$2'); }\""

  let (outp, errC) = execCmdEx(cmd % [path, tempDir])
  if errC != 0:
    raise newException(ChooseNimError, "Unable to extract ZIP. Error was $1" % outp)

  # Determine which directory to copy.
  var srcDir = tempDir
  let contents = toSeq(walkDir(srcDir))
  if contents.len == 1 and skipOuterDirs:
    # Skip the outer directory.
    srcDir = contents[0][1]

  # Finally copy the directory to what the user specified.
  copyDir(srcDir, extractDir)

proc extract*(path: string, extractDir: string) =
  display("Extracting", path.extractFilename(), priority = HighPriority)

  let ext = path.splitFile().ext
  var newPath = path
  case ext
  of ".zip":
    extractZip(path, extractDir)
    return
  of ".xz":
    # We need to decompress manually.
    let unxzPath = findExe("unxz")
    if unxzPath.len == 0:
      let msg = "Cannot decompress xz, `unxz` not in PATH"
      raise newException(ChooseNimError, msg)

    let tarFile = newPath.changeFileExt("") # This will remove the .xz
    # `unxz` complains when the .tar file already exists.
    removeFile(tarFile)
    doCmdRaw("unxz \"$1\"" % newPath)
    newPath = tarFile
  of ".gz":
    # untar package will take care of this.
    discard
  else:
    raise newException(ChooseNimError, "Invalid archive format " & ext)

  try:
    var file = newTarFile(newPath)
    file.extract(extractDir)
  except Exception as exc:
    raise newException(ChooseNimError, "Unable to extract. Error was '$1'." %
                       exc.msg)

proc getProxy*(): Proxy =
  ## Returns ``nil`` if no proxy is specified.
  var url = ""
  try:
    if existsEnv("http_proxy"):
      url = getEnv("http_proxy")
    elif existsEnv("https_proxy"):
      url = getEnv("https_proxy")
  except ValueError:
    display("Warning:", "Unable to parse proxy from environment: " &
        getCurrentExceptionMsg(), Warning, HighPriority)

  if url.len > 0:
    var parsed = parseUri(url)
    if parsed.scheme.len == 0 or parsed.hostname.len == 0:
      parsed = parseUri("http://" & url)
    let auth =
      if parsed.username.len > 0: parsed.username & ":" & parsed.password
      else: ""
    return newProxy($parsed, auth)
  else:
    return nil

proc getGccArch*(params: CliParams): int =
  var
    outp = ""
    errC = 0

  when defined(windows):
    # Add MingW bin dir to PATH so getGccArch can find gcc.
    let pathEnv = getEnv("PATH")
    if not isDefaultCCInPath(params) and dirExists(params.getMingwBin()):
      putEnv("PATH", params.getMingwBin() & PathSep & pathEnv)

    (outp, errC) = execCmdEx("cmd /c echo int main^(^) { return sizeof^(void *^); } | gcc -xc - -o archtest && archtest")

    putEnv("PATH", pathEnv)
  else:
    (outp, errC) = execCmdEx("sh echo \"int main() { return sizeof(void *); }\" | gcc -xc - -o archtest && archtest")

  removeFile("archtest".addFileExt(ExeExt))
  return errC * 8
