" Name:    gnupg.vim
" Version: $Id: gnupg.vim 3026 2010-01-27 08:18:04Z mbr $
" Author:  Markus Braun <markus.braun@krawel.de>
" Summary: Vim plugin for transparent editing of gpg encrypted files.
" Licence: This program is free software; you can redistribute it and/or
"          modify it under the terms of the GNU General Public License.
"          See http://www.gnu.org/copyleft/gpl.txt
"
" Section: Documentation {{{1
"
" Description: {{{2
"
"   This script implements transparent editing of gpg encrypted files. The
"   filename must have a ".gpg", ".pgp" or ".asc" suffix. When opening such
"   a file the content is decrypted, when opening a new file the script will
"   ask for the recipients of the encrypted file. The file content will be
"   encrypted to all recipients before it is written. The script turns off
"   viminfo and swapfile to increase security.
"
" Installation: {{{2
"
"   Copy the gnupg.vim file to the $HOME/.vim/plugin directory.
"   Refer to ':help add-plugin', ':help add-global-plugin' and ':help
"   runtimepath' for more details about Vim plugins.
"
"   From "man 1 gpg-agent":
"
"   ...
"   You should always add the following lines to your .bashrc or whatever
"   initialization file is used for all shell invocations:
"
"        GPG_TTY=`tty`
"        export GPG_TTY
"
"   It is important that this environment variable always reflects the out‐
"   put of the tty command. For W32 systems this option is not required.
"   ...
"
"   Most distributions provide software to ease handling of gpg and gpg-agent.
"   Examples are keychain or seahorse.
"
" Commands: {{{2
"
"   :GPGEditRecipients
"     Opens a scratch buffer to change the list of recipients. Recipients that
"     are unknown (not in your public key) are highlighted and have
"     a prepended "!". Closing the buffer makes the changes permanent.
"
"   :GPGViewRecipients
"     Prints the list of recipients.
"
"   :GPGEditOptions
"     Opens a scratch buffer to change the options for encryption (symmetric,
"     asymmetric, signing). Closing the buffer makes the changes permanent.
"     WARNING: There is no check of the entered options, so you need to know
"     what you are doing.
"
"   :GPGViewOptions
"     Prints the list of options.
"
" Variables: {{{2
"
"   g:GPGExecutable
"     If set used as gpg executable, otherwise the system chooses what is run
"     when "gpg" is called. Defaults to "gpg".
"
"   g:GPGUseAgent
"     If set to 0 a possible available gpg-agent won't be used. Defaults to 1.
"
"   g:GPGPreferSymmetric
"     If set to 1 symmetric encryption is preferred for new files. Defaults to 0.
"
"   g:GPGPreferArmor
"     If set to 1 armored data is preferred for new files. Defaults to 0.
"
"   g:GPGPreferSign
"     If set to 1 signed data is preferred for new files. Defaults to 0.
"
"   g:GPGDefaultRecipients
"     If set, these recipients are used as defaults when no other recipient is
"     defined. This variable is a Vim list. Default is unset.
"
" Known Issues: {{{2
"
"   In some cases gvim can't decryt files

"   This is caused by the fact that a running gvim has no TTY and thus gpg is
"   not able to ask for the passphrase by itself. This is a problem for Windows
"   and Linux versions of gvim and could not be solved unless a "terminal
"   emulation" is implemented for gvim. To circumvent this you have to use any
"   combination of gpg-agent and a graphical pinentry program:
"
"     - gpg-agent only:
"         you need to provide the passphrase for the needed key to gpg-agent
"         in a terminal before you open files with gvim which require this key.
"
"     - pinentry only:
"         you will get a popup window every time you open a file that needs to
"         be decrypted.
"
"     - gpgagent and pinentry:
"         you will get a popup window the first time you open a file that
"         needs to be decrypted.
"
" Credits: {{{2
"
"   - Mathieu Clabaut for inspirations through his vimspell.vim script.
"   - Richard Bronosky for patch to enable ".pgp" suffix.
"   - Erik Remmelzwaal for patch to enable windows support and patient beta
"     testing.
"   - Lars Becker for patch to make gpg2 working.
"   - Thomas Arendsen Hein for patch to convert encoding of gpg output
"   - Karl-Heinz Ruskowski for patch to fix unknown recipients and trust model
"     and patient beta testing.
"   - Giel van Schijndel for patch to get GPG_TTY dynamically.
"   - Sebastian Luettich for patch to fix issue with symmetric encryption an set
"     recipients.
"   - Tim Swast for patch to generate signed files
"
" Section: Plugin header {{{1

" guard against multiple loads {{{2
if (exists("g:loaded_gnupg") || &cp || exists("#BufReadPre#*.\(gpg\|asc\|pgp\)"))
  finish
endif
let g:loaded_gnupg = "$Revision: 3026 $"

" check for correct vim version {{{2
if (v:version < 700)
  echohl ErrorMsg | echo 'plugin gnupg.vim requires Vim version >= 7.0' | echohl None
  finish
endif

" Section: Autocmd setup {{{1

augroup GnuPG
  autocmd!

  " initialize the internal variables
  autocmd BufNewFile,BufReadPre,FileReadPre      *.\(gpg\|asc\|pgp\) call s:GPGInit()
  " force the user to edit the recipient list if he opens a new file and public
  " keys are preferred
  autocmd BufNewFile                             *.\(gpg\|asc\|pgp\) if (exists("g:GPGPreferSymmetric") && g:GPGPreferSymmetric == 0) | call s:GPGEditRecipients() | endif
  " do the decryption
  autocmd BufReadPost,FileReadPost               *.\(gpg\|asc\|pgp\) call s:GPGDecrypt()

  " convert all text to encrypted text before writing
  autocmd BufWritePre,FileWritePre               *.\(gpg\|asc\|pgp\) call s:GPGEncrypt()
  " undo the encryption so we are back in the normal text, directly
  " after the file has been written.
  autocmd BufWritePost,FileWritePost             *.\(gpg\|asc\|pgp\) call s:GPGEncryptPost()

  " cleanup on leaving vim
  autocmd VimLeave                               *.\(gpg\|asc\|pgp\) call s:GPGCleanup()
augroup END

" Section: Constants {{{1

let s:GPGMagicString = "\t \t"

" Section: Highlight setup {{{1

highlight default link GPGWarning WarningMsg
highlight default link GPGError ErrorMsg
highlight default link GPGHighlightUnknownRecipient ErrorMsg

" Section: Functions {{{1

" Function: s:GPGInit() {{{2
"
" initialize the plugin
"
function s:GPGInit()
  call s:GPGDebug(3, ">>>>>>>> Entering s:GPGInit()")

  " first make sure nothing is written to ~/.viminfo while editing
  " an encrypted file.
  set viminfo=

  " we don't want a swap file, as it writes unencrypted data to disk
  set noswapfile

  " check what gpg command to use
  if (!exists("g:GPGExecutable"))
    let g:GPGExecutable = "gpg --trust-model always"
  endif

  " check if gpg-agent is allowed
  if (!exists("g:GPGUseAgent"))
    let g:GPGUseAgent = 1
  endif

  " check if symmetric encryption is preferred
  if (!exists("g:GPGPreferSymmetric"))
    let g:GPGPreferSymmetric = 0
  endif

  " check if armored files are preferred
  if (!exists("g:GPGPreferArmor"))
    let g:GPGPreferArmor = 0
  endif

  " check if signed files are preferred
  if (!exists("g:GPGPreferSign"))
    let g:GPGPreferSign = 0
  endif

  " start with empty default recipients if none is defined so far
  if (!exists("g:GPGDefaultRecipients"))
    let g:GPGDefaultRecipients = []
  endif

  " print version
  call s:GPGDebug(1, "gnupg.vim ". g:loaded_gnupg)

  " determine if gnupg can use the gpg-agent
  if (exists("$GPG_AGENT_INFO") && g:GPGUseAgent == 1)
    if (!exists("$GPG_TTY") && !has("gui_running"))
      let $GPG_TTY = system("tty")
      if (v:shell_error)
        let $GPG_TTY = ""
        echohl GPGError
        echom "The GPG_TTY is not set and no TTY could be found using the `tty` command!"
        echom "gpg-agent might not work."
        echohl None
      endif
    endif
    let s:GPGCommand = g:GPGExecutable . " --use-agent"
  else
    let s:GPGCommand = g:GPGExecutable . " --no-use-agent"
  endif

  " don't use tty in gvim
  " FIXME find a better way to avoid an error.
  "       with this solution only --use-agent will work
  if (has("gui_running"))
    let s:GPGCommand = s:GPGCommand . " --no-tty"
  endif

  " setup shell environment for unix and windows
  let s:shellredirsave = &shellredir
  let s:shellsave = &shell
  if (has("unix"))
    " unix specific settings
    let s:shellredir = ">%s 2>&1"
    let s:shell = '/bin/sh'
    let s:stderrredirnull = '2>/dev/null'
    let s:GPGCommand = "LANG=C LC_ALL=C " . s:GPGCommand
  else
    " windows specific settings
    let s:shellredir = '>%s'
    let s:shell = &shell
    let s:stderrredirnull = '2>nul'
  endif

  call s:GPGDebug(3, "shellredirsave: " . s:shellredirsave)
  call s:GPGDebug(3, "shellsave: " . s:shellsave)

  call s:GPGDebug(3, "shell: " . s:shell)
  call s:GPGDebug(3, "shellcmdflag: " . &shellcmdflag)
  call s:GPGDebug(3, "shellxquote: " . &shellxquote)
  call s:GPGDebug(3, "shellredir: " . s:shellredir)
  call s:GPGDebug(3, "stderrredirnull: " . s:stderrredirnull)

  call s:GPGDebug(3, "shell implementation: " . resolve(s:shell))

  " find the supported algorithms
  let commandline = s:GPGCommand . " --version"
  call s:GPGDebug(2, "command: ". commandline)
  let &shellredir = s:shellredir
  let &shell = s:shell
  let output = system(commandline)
  let &shellredir = s:shellredirsave
  let &shell = s:shellsave
  call s:GPGDebug(2, "output: ". output)

  let s:GPGPubkey = substitute(output, ".*Pubkey: \\(.\\{-}\\)\n.*", "\\1", "")
  let s:GPGCipher = substitute(output, ".*Cipher: \\(.\\{-}\\)\n.*", "\\1", "")
  let s:GPGHash = substitute(output, ".*Hash: \\(.\\{-}\\)\n.*", "\\1", "")
  let s:GPGCompress = substitute(output, ".*Compress.\\{-}: \\(.\\{-}\\)\n.*", "\\1", "")

  call s:GPGDebug(2, "public key algorithms: " . s:GPGPubkey)
  call s:GPGDebug(2, "cipher algorithms: " . s:GPGCipher)
  call s:GPGDebug(2, "hashing algorithms: " . s:GPGHash)
  call s:GPGDebug(2, "compression algorithms: " . s:GPGCompress)
  call s:GPGDebug(3, "<<<<<<<< Leaving s:GPGInit()")
endfunction

" Function: s:GPGCleanup() {{{2
"
" cleanup on leaving vim
"
function s:GPGCleanup()
  call s:GPGDebug(3, ">>>>>>>> Entering s:GPGCleanup()")

  " wipe out screen
  new +only
  redraw!

  call s:GPGDebug(3, "<<<<<<<< Leaving s:GPGCleanup()")
endfunction

" Function: s:GPGDecrypt() {{{2
"
" decrypt the buffer and find all recipients of the encrypted file
"
function s:GPGDecrypt()
  call s:GPGDebug(3, ">>>>>>>> Entering s:GPGDecrypt()")

  " switch to binary mode to read the encrypted file
  set bin

  " get the filename of the current buffer
  let filename = escape(expand("%:p"), '\"')

  " clear GPGEncrypted, GPGRecipients and GPGOptions
  let b:GPGEncrypted = 0
  let b:GPGRecipients = []
  let b:GPGOptions = []

  " find the recipients of the file
  let commandline = s:GPGCommand . " --verbose --decrypt --list-only --dry-run --batch --no-use-agent --logger-fd 1 \"" . filename . "\""
  call s:GPGDebug(3, "command: " . commandline)
  let &shellredir = s:shellredir
  let &shell = s:shell
  let output = system(commandline)
  let &shellredir = s:shellredirsave
  let &shell = s:shellsave
  call s:GPGDebug(3, "output: ". output)

  " check if the file is symmetric/asymmetric encrypted
  if (match(output, "gpg: encrypted with [[:digit:]]\\+ passphrase") >= 0)
    " file is symmetric encrypted
    let b:GPGEncrypted = 1
    call s:GPGDebug(1, "this file is symmetric encrypted")

    let b:GPGOptions += ["symmetric"]

    " find the used cipher algorithm
    let cipher = substitute(output, ".*gpg: \\([^ ]\\+\\) encrypted data.*", "\\1", "")
    if (match(s:GPGCipher, "\\<" . cipher . "\\>") >= 0)
      let b:GPGOptions += ["cipher-algo " . cipher]
      call s:GPGDebug(1, "cipher-algo is " . cipher)
    else
      echohl GPGWarning
      echom "The cipher " . cipher . " is not known by the local gpg command. Using default!"
      echo
      echohl None
    endif
  elseif (match(output, "gpg: public key is [[:xdigit:]]\\{8}") >= 0)
    " file is asymmetric encrypted
    let b:GPGEncrypted = 1
    call s:GPGDebug(1, "this file is asymmetric encrypted")

    let b:GPGOptions += ["encrypt"]

    " find the used public keys
    let start = match(output, "gpg: public key is [[:xdigit:]]\\{8}")
    while (start >= 0)
      let start = start + strlen("gpg: public key is ")
      let recipient = strpart(output, start, 8)
      call s:GPGDebug(1, "recipient is " . recipient)
      let name = s:GPGNameToID(recipient)
      if (strlen(name) > 0)
        let b:GPGRecipients += [name]
        call s:GPGDebug(1, "name of recipient is " . name)
      else
        let b:GPGRecipients += [recipient]
        echohl GPGWarning
        echom "The recipient \"" . recipient . "\" is not in your public keyring!"
        echohl None
      end
      let start = match(output, "gpg: public key is [[:xdigit:]]\\{8}", start)
    endwhile
  else
    " file is not encrypted
    let b:GPGEncrypted = 0
    call s:GPGDebug(1, "this file is not encrypted")
    echohl GPGWarning
    echom "File is not encrypted, all GPG functions disabled!"
    echohl None
    set nobin
    call s:GPGDebug(3, "<<<<<<<< Leaving s:GPGDecrypt()")
    return
  endif

  " check if the message is armored
  if (match(output, "gpg: armor header") >= 0)
    call s:GPGDebug(1, "this file is armored")
    let b:GPGOptions += ["armor"]
  endif

  " finally decrypt the buffer content
  " since even with the --quiet option passphrase typos will be reported,
  " we must redirect stderr (using shell temporarily)
  call s:GPGDebug(1, "decrypting file")
  let commandline = "'[,']!" . s:GPGCommand . " --quiet --decrypt " . s:stderrredirnull
  call s:GPGDebug(1, "command: " . commandline)
  let &shellredir = s:shellredir
  let &shell = s:shell
  execute commandline
  let &shellredir = s:shellredirsave
  let &shell = s:shellsave
  if (v:shell_error) " message could not be decrypted
    silent u
    echohl GPGError
    let blackhole = input("Message could not be decrypted! (Press ENTER)")
    echohl None
    bwipeout
    set nobin
    call s:GPGDebug(3, "<<<<<<<< Leaving s:GPGDecrypt()")
    return
  endif

  " turn off binary mode
  set nobin

  " call the autocommand for the file minus .gpg$
  execute ":doautocmd BufReadPost " . escape(expand("%:r"), ' *?\"'."'")
  call s:GPGDebug(2, "called autocommand for " . escape(expand("%:r"), ' *?\"'."'"))

  " refresh screen
  redraw!

  call s:GPGDebug(3, "<<<<<<<< Leaving s:GPGDecrypt()")
endfunction

" Function: s:GPGEncrypt() {{{2
"
" encrypts the buffer to all previous recipients
"
function s:GPGEncrypt()
  call s:GPGDebug(3, ">>>>>>>> Entering s:GPGEncrypt()")

  " save window view
  let s:GPGWindowView = winsaveview()
  call s:GPGDebug(2, "saved window view " . string(s:GPGWindowView))

  " store encoding and switch to a safe one
  if (&fileencoding != &encoding)
    let s:GPGEncoding = &encoding
    let &encoding = &fileencoding
    call s:GPGDebug(2, "encoding was \"" . s:GPGEncoding . "\", switched to \"" . &encoding . "\"")
  else
    let s:GPGEncoding = ""
    call s:GPGDebug(2, "encoding and fileencoding are the same (\"" . &encoding . "\"), not switching")
  endif

  " switch buffer to binary mode
  set bin

  " guard for unencrypted files
  if (!exists("b:GPGEncrypted") || b:GPGEncrypted == 0)
    echohl GPGError
    let blackhole = input("Message could not be encrypted! File might be empty! (Press ENTER)")
    echohl None
    call s:GPGDebug(3, "<<<<<<<< Leaving s:GPGEncrypt()")
    return
  endif

  " initialize GPGOptions if not happened before
  if (!exists("b:GPGOptions") || len(b:GPGOptions) == 0)
    let b:GPGOptions = []
    if (exists("g:GPGPreferSymmetric") && g:GPGPreferSymmetric == 1)
      let b:GPGOptions += ["symmetric"]
      let b:GPGRecipients = []
    else
      let b:GPGOptions += ["encrypt"]
    endif
    if (exists("g:GPGPreferArmor") && g:GPGPreferArmor == 1)
      let b:GPGOptions += ["armor"]
    endif
    if (exists("g:GPGPreferSign") && g:GPGPreferSign == 1)
      let b:GPGOptions += ["sign"]
    endif
    call s:GPGDebug(1, "no options set, so using default options: " . string(b:GPGOptions))
  endif

  " built list of options
  let options = ""
  for option in b:GPGOptions
    let options = options . " --" . option . " "
  endfor

  " check here again if all recipients are available in the keyring
  let [ recipients, unknownrecipients ] = s:GPGCheckRecipients(b:GPGRecipients)

  " check if there are unknown recipients and warn
  if (len(unknownrecipients) > 0)
    echohl GPGWarning
    echom "Please use GPGEditRecipients to correct!!"
    echo
    echohl None

    " Let user know whats happend and copy known_recipients back to buffer
    let dummy = input("Press ENTER to quit")
  endif

  " built list of recipients
  if (len(recipients) > 0)
    for gpgid in recipients
      let options = options . " -r " . gpgid
    endfor
  else
    if (match(b:GPGOptions, "encrypt") >= 0)
      echohl GPGError
      echom "There are no recipients!!"
      echom "Please use GPGEditRecipients to correct!!"
      echo
      echohl None
    endif
  endif

  " encrypt the buffer
  let commandline = "'[,']!" . s:GPGCommand . " --quiet --no-encrypt-to " . options . " " . s:stderrredirnull
  call s:GPGDebug(1, "command: " . commandline)
  let &shellredir = s:shellredir
  let &shell = s:shell
  silent execute commandline
  let &shellredir = s:shellredirsave
  let &shell = s:shellsave
  if (v:shell_error) " message could not be encrypted
    " delete content of the buffer to be sure no data is written unencrypted
    " content will be recovered in GPGEncryptPost()
    silent normal! 1GdG

    echohl GPGError
    let blackhole = input("Message could not be encrypted! File might be empty! (Press ENTER)")
    echohl None
    call s:GPGDebug(3, "<<<<<<<< Leaving s:GPGEncrypt()")
    return
  endif

  call s:GPGDebug(3, "<<<<<<<< Leaving s:GPGEncrypt()")
endfunction

" Function: s:GPGEncryptPost() {{{2
"
" undo changes don by encrypt, after writing
"
function s:GPGEncryptPost()
  call s:GPGDebug(3, ">>>>>>>> Entering s:GPGEncryptPost()")

  " guard for unencrypted files
  if (exists("b:GPGEncrypted") && b:GPGEncrypted == 0)
    call s:GPGDebug(3, "<<<<<<<< Leaving s:GPGEncryptPost()")
    return
  endif

  " undo encryption of buffer content
  silent u

  " switch back from binary mode
  set nobin

  " restore encoding
  if (s:GPGEncoding != "")
    let &encoding = s:GPGEncoding
    call s:GPGDebug(2, "restored encoding \"" . &encoding . "\"")
  endif

  " restore window view
  call winrestview(s:GPGWindowView)
  call s:GPGDebug(2, "restored window view" . string(s:GPGWindowView))

  " refresh screen
  redraw!

  call s:GPGDebug(3, "<<<<<<<< Leaving s:GPGEncryptPost()")
endfunction

" Function: s:GPGViewRecipients() {{{2
"
" echo the recipients
"
function s:GPGViewRecipients()
  call s:GPGDebug(3, ">>>>>>>> Entering s:GPGViewRecipients()")

  " guard for unencrypted files
  if (exists("b:GPGEncrypted") && b:GPGEncrypted == 0)
    echohl GPGWarning
    echom "File is not encrypted, all GPG functions disabled!"
    echohl None
    call s:GPGDebug(3, "<<<<<<<< Leaving s:GPGViewRecipients()")
    return
  endif

  let [ recipients, unknownrecipients ] = s:GPGCheckRecipients(b:GPGRecipients)

  echo 'This file has following recipients (Unknown recipients have a prepended "!"):'
  " echo the recipients
  for name in recipients
    let name = s:GPGIDToName(name)
    echo name
  endfor

  " echo the unknown recipients
  echohl GPGWarning
  for name in unknownrecipients
    let name = "!" . name
    echo name
  endfor
  echohl None

  " check if there is any known recipient
  if (len(recipients) == 0)
    echohl GPGError
    echom 'There are no known recipients!'
    echohl None
  endif

  call s:GPGDebug(3, "<<<<<<<< Leaving s:GPGViewRecipients()")
endfunction

" Function: s:GPGEditRecipients() {{{2
"
" create a scratch buffer with all recipients to add/remove recipients
"
function s:GPGEditRecipients()
  call s:GPGDebug(3, ">>>>>>>> Entering s:GPGEditRecipients()")

  " guard for unencrypted files
  if (exists("b:GPGEncrypted") && b:GPGEncrypted == 0)
    echohl GPGWarning
    echom "File is not encrypted, all GPG functions disabled!"
    echohl None
    call s:GPGDebug(3, "<<<<<<<< Leaving s:GPGEditRecipients()")
    return
  endif

  " only do this if it isn't already a GPGRecipients_* buffer
  if (match(bufname("%"), "^\\(GPGRecipients_\\|GPGOptions_\\)") != 0 && match(bufname("%"), "\.\\(gpg\\|asc\\|pgp\\)$") >= 0)

    " save buffer name
    let buffername = bufname("%")
    let editbuffername = "GPGRecipients_" . buffername

    " check if this buffer exists
    if (!bufexists(editbuffername))
      " create scratch buffer
      execute 'silent! split ' . escape(editbuffername, ' *?\"'."'")

      " add a autocommand to regenerate the recipients after a write
      autocmd BufHidden,BufUnload,BufWriteCmd <buffer> call s:GPGFinishRecipientsBuffer()
    else
      if (bufwinnr(editbuffername) >= 0)
        " switch to scratch buffer window
        execute 'silent! ' . bufwinnr(editbuffername) . "wincmd w"
      else
        " split scratch buffer window
        execute 'silent! sbuffer ' . escape(editbuffername, ' *?\"'."'")

        " add a autocommand to regenerate the recipients after a write
        autocmd BufHidden,BufUnload,BufWriteCmd <buffer> call s:GPGFinishRecipientsBuffer()
      endif

      " empty the buffer
      silent normal! 1GdG
    endif

    " Mark the buffer as a scratch buffer
    setlocal buftype=acwrite
    setlocal bufhidden=hide
    setlocal noswapfile
    setlocal nowrap
    setlocal nobuflisted
    setlocal nonumber

    " so we know for which other buffer this edit buffer is
    let b:GPGCorrespondingTo = buffername

    " put some comments to the scratch buffer
    silent put ='GPG: ----------------------------------------------------------------------'
    silent put ='GPG: Please edit the list of recipients, one recipient per line.'
    silent put ='GPG: Unknown recipients have a prepended \"!\".'
    silent put ='GPG: Lines beginning with \"GPG:\" are removed automatically.'
    silent put ='GPG: Data after recipients between and including \"(\" and \")\" is ignored.'
    silent put ='GPG: Closing this buffer commits changes.'
    silent put ='GPG: ----------------------------------------------------------------------'

    " get the recipients
    let [ recipients, unknownrecipients ] = s:GPGCheckRecipients(getbufvar(b:GPGCorrespondingTo, "GPGRecipients"))

    " if there are no known or unknown recipients, use the default ones
    if (len(recipients) == 0 && len(unknownrecipients) == 0)
      if (type(g:GPGDefaultRecipients) == type([]))
        let [ recipients, unknownrecipients ] = s:GPGCheckRecipients(g:GPGDefaultRecipients)
      else
        echohl GPGWarning
        echom "g:GPGDefaultRecipients is not a Vim list, please correct this in your vimrc!"
        echohl None
      endif
    endif

    " put the recipients in the scratch buffer
    for name in recipients
      let name = s:GPGIDToName(name)
      silent put =name
    endfor

    " put the unknown recipients in the scratch buffer
    let syntaxPattern = "\\(nonexxistinwordinthisbuffer"
    for name in unknownrecipients
      let name = "!" . name
      let syntaxPattern = syntaxPattern . "\\|" . name
      silent put =name
    endfor
    let syntaxPattern = syntaxPattern . "\\)"

    " define highlight
    if (has("syntax") && exists("g:syntax_on"))
      execute 'syntax match GPGUnknownRecipient    "' . syntaxPattern . '"'
      highlight clear GPGUnknownRecipient
      highlight link GPGUnknownRecipient  GPGHighlightUnknownRecipient

      syntax match GPGComment "^GPG:.*$"
      execute 'syntax match GPGComment "' . s:GPGMagicString . '.*$"'
      highlight clear GPGComment
      highlight link GPGComment Comment
    endif

    " delete the empty first line
    silent normal! 1Gdd

    " jump to the first recipient
    silent normal! G

  endif

  call s:GPGDebug(3, "<<<<<<<< Leaving s:GPGEditRecipients()")
endfunction

" Function: s:GPGFinishRecipientsBuffer() {{{2
"
" create a new recipient list from RecipientsBuffer
"
function s:GPGFinishRecipientsBuffer()
  call s:GPGDebug(3, ">>>>>>>> Entering s:GPGFinishRecipientsBuffer()")

  " guard for unencrypted files
  if (exists("b:GPGEncrypted") && b:GPGEncrypted == 0)
    echohl GPGWarning
    echom "File is not encrypted, all GPG functions disabled!"
    echohl None
    call s:GPGDebug(3, "<<<<<<<< Leaving s:GPGFinishRecipientsBuffer()")
    return
  endif

  " go to buffer before doing work
  if (bufnr("%") != expand("<abuf>"))
    " switch to scratch buffer window
    execute 'silent! ' . bufwinnr(expand("<afile>")) . "wincmd w"
  endif

  " delete the autocommand
  autocmd! * <buffer>


  " get the recipients from the scratch buffer
  let recipients = []
  let lines = getline(1,"$")
  for recipient in lines
    " delete all text after magic string
    let recipient = substitute(recipient, s:GPGMagicString . ".*$", "", "")

    " delete all spaces at beginning and end of the recipient
    " also delete a '!' at the beginning of the recipient
    let recipient = substitute(recipient, "^[[:space:]!]*\\(.\\{-}\\)[[:space:]]*$", "\\1", "")

    " delete comment lines
    let recipient = substitute(recipient, "^GPG:.*$", "", "")

    " only do this if the line is not empty
    if (strlen(recipient) > 0)
      let gpgid = s:GPGNameToID(recipient)
      if (strlen(gpgid) > 0)
        if (match(recipients, gpgid) < 0)
          let recipients += [gpgid]
        endif
      else
        if (match(recipients, recipient) < 0)
          let recipients += [recipient]
          echohl GPGWarning
          echom "The recipient \"" . recipient . "\" is not in your public keyring!"
          echohl None
        endif
      endif
    endif
  endfor

  " write back the new recipient list to the corresponding buffer and mark it
  " as modified. Buffer is now for sure a encrypted buffer.
  call setbufvar(b:GPGCorrespondingTo, "GPGRecipients", recipients)
  call setbufvar(b:GPGCorrespondingTo, "&mod", 1)
  call setbufvar(b:GPGCorrespondingTo, "GPGEncrypted", 1)

  " check if there is any known recipient
  if (len(recipients) == 0)
    echohl GPGError
    echom 'There are no known recipients!'
    echohl None
  endif

  " reset modified flag
  set nomodified

  call s:GPGDebug(3, "<<<<<<<< Leaving s:GPGFinishRecipientsBuffer()")
endfunction

" Function: s:GPGViewOptions() {{{2
"
" echo the recipients
"
function s:GPGViewOptions()
  call s:GPGDebug(3, ">>>>>>>> Entering s:GPGViewOptions()")

  " guard for unencrypted files
  if (exists("b:GPGEncrypted") && b:GPGEncrypted == 0)
    echohl GPGWarning
    echom "File is not encrypted, all GPG functions disabled!"
    echohl None
    call s:GPGDebug(3, "<<<<<<<< Leaving s:GPGViewOptions()")
    return
  endif

  if (exists("b:GPGOptions"))
    echo 'This file has following options:'
    " echo the options
    for option in b:GPGOptions
      echo option
    endfor
  endif

  call s:GPGDebug(3, "<<<<<<<< Leaving s:GPGViewOptions()")
endfunction

" Function: s:GPGEditOptions() {{{2
"
" create a scratch buffer with all recipients to add/remove recipients
"
function s:GPGEditOptions()
  call s:GPGDebug(3, ">>>>>>>> Entering s:GPGEditOptions()")

  " guard for unencrypted files
  if (exists("b:GPGEncrypted") && b:GPGEncrypted == 0)
    echohl GPGWarning
    echom "File is not encrypted, all GPG functions disabled!"
    echohl None
    call s:GPGDebug(3, "<<<<<<<< Leaving s:GPGEditOptions()")
    return
  endif

  " only do this if it isn't already a GPGOptions_* buffer
  if (match(bufname("%"), "^\\(GPGRecipients_\\|GPGOptions_\\)") != 0 && match(bufname("%"), "\.\\(gpg\\|asc\\|pgp\\)$") >= 0)

    " save buffer name
    let buffername = bufname("%")
    let editbuffername = "GPGOptions_" . buffername

    " check if this buffer exists
    if (!bufexists(editbuffername))
      " create scratch buffer
      execute 'silent! split ' . escape(editbuffername, ' *?\"'."'")

      " add a autocommand to regenerate the options after a write
      autocmd BufHidden,BufUnload,BufWriteCmd <buffer> call s:GPGFinishOptionsBuffer()
    else
      if (bufwinnr(editbuffername) >= 0)
        " switch to scratch buffer window
        execute 'silent! ' . bufwinnr(editbuffername) . "wincmd w"
      else
        " split scratch buffer window
        execute 'silent! sbuffer ' . escape(editbuffername, ' *?\"'."'")

        " add a autocommand to regenerate the options after a write
        autocmd BufHidden,BufUnload,BufWriteCmd <buffer> call s:GPGFinishOptionsBuffer()
      endif

      " empty the buffer
      silent normal! 1GdG
    endif

    " Mark the buffer as a scratch buffer
    setlocal buftype=nofile
    setlocal noswapfile
    setlocal nowrap
    setlocal nobuflisted
    setlocal nonumber

    " so we know for which other buffer this edit buffer is
    let b:GPGCorrespondingTo = buffername

    " put some comments to the scratch buffer
    silent put ='GPG: ----------------------------------------------------------------------'
    silent put ='GPG: THERE IS NO CHECK OF THE ENTERED OPTIONS!'
    silent put ='GPG: YOU NEED TO KNOW WHAT YOU ARE DOING!'
    silent put ='GPG: IF IN DOUBT, QUICKLY EXIT USING :x OR :bd.'
    silent put ='GPG: Please edit the list of options, one option per line.'
    silent put ='GPG: Please refer to the gpg documentation for valid options.'
    silent put ='GPG: Lines beginning with \"GPG:\" are removed automatically.'
    silent put ='GPG: Closing this buffer commits changes.'
    silent put ='GPG: ----------------------------------------------------------------------'

    " put the options in the scratch buffer
    let options = getbufvar(b:GPGCorrespondingTo, "GPGOptions")

    for option in options
      silent put =option
    endfor

    " delete the empty first line
    silent normal! 1Gdd

    " jump to the first option
    silent normal! G

    " define highlight
    if (has("syntax") && exists("g:syntax_on"))
      syntax match GPGComment "^GPG:.*$"
      highlight clear GPGComment
      highlight link GPGComment Comment
    endif
  endif

  call s:GPGDebug(3, "<<<<<<<< Leaving s:GPGEditOptions()")
endfunction

" Function: s:GPGFinishOptionsBuffer() {{{2
"
" create a new option list from OptionsBuffer
"
function s:GPGFinishOptionsBuffer()
  call s:GPGDebug(3, ">>>>>>>> Entering s:GPGFinishOptionsBuffer()")

  " guard for unencrypted files
  if (exists("b:GPGEncrypted") && b:GPGEncrypted == 0)
    echohl GPGWarning
    echom "File is not encrypted, all GPG functions disabled!"
    echohl None
    call s:GPGDebug(3, "<<<<<<<< Leaving s:GPGFinishOptionsBuffer()")
    return
  endif

  " go to buffer before doing work
  if (bufnr("%") != expand("<abuf>"))
    " switch to scratch buffer window
    execute 'silent! ' . bufwinnr(expand("<afile>")) . "wincmd w"
  endif

  " clear options and unknownOptions
  let options = []
  let unknownOptions = []

  " delete the autocommand
  autocmd! * <buffer>

  " get the options from the scratch buffer
  let lines = getline(1, "$")
  for option in lines
    " delete all spaces at beginning and end of the option
    " also delete a '!' at the beginning of the option
    let option = substitute(option, "^[[:space:]!]*\\(.\\{-}\\)[[:space:]]*$", "\\1", "")
    " delete comment lines
    let option = substitute(option, "^GPG:.*$", "", "")

    " only do this if the line is not empty
    if (strlen(option) > 0 && match(options, option) < 0)
      let options += [option]
    endif
  endfor

  " write back the new option list to the corresponding buffer and mark it
  " as modified
  call setbufvar(b:GPGCorrespondingTo, "GPGOptions", options)
  call setbufvar(b:GPGCorrespondingTo, "&mod", 1)

  " reset modified flag
  set nomodified

  call s:GPGDebug(3, "<<<<<<<< Leaving s:GPGFinishOptionsBuffer()")
endfunction

" Function: s:GPGCheckRecipients(tocheck) {{{2
"
" check if recipients are known
" Returns: two lists recipients and unknownrecipients
"
function s:GPGCheckRecipients(tocheck)
  call s:GPGDebug(3, ">>>>>>>> Entering s:GPGCheckRecipients()")

  let recipients = []
  let unknownrecipients = []

  if (type(a:tocheck) == type([]))
    for recipient in a:tocheck
      let gpgid = s:GPGNameToID(recipient)
      if (strlen(gpgid) > 0)
        if (match(recipients, gpgid) < 0)
          let recipients += [gpgid]
        endif
      else
        if (match(unknownrecipients, recipient) < 0)
          let unknownrecipients += [recipient]
          echohl GPGWarning
          echom "The recipient \"" . recipient . "\" is not in your public keyring!"
          echohl None
        endif
      end
    endfor
  endif

  call s:GPGDebug(2, "recipients are: " . string(recipients))
  call s:GPGDebug(2, "unknown recipients are: " . string(unknownrecipients))

  call s:GPGDebug(3, "<<<<<<<< Leaving s:GPGCheckRecipients()")
  return [ recipients, unknownrecipients ]
endfunction

" Function: s:GPGNameToID(name) {{{2
"
" find GPG key ID corresponding to a name
" Returns: ID for the given name
"
function s:GPGNameToID(name)
  call s:GPGDebug(3, ">>>>>>>> Entering s:GPGNameToID()")

  " ask gpg for the id for a name
  let commandline = s:GPGCommand . " --quiet --with-colons --fixed-list-mode --list-keys \"" . a:name . "\""
  call s:GPGDebug(2, "command: ". commandline)
  let &shellredir = s:shellredir
  let &shell = s:shell
  let output = system(commandline)
  let &shellredir = s:shellredirsave
  let &shell = s:shellsave
  call s:GPGDebug(2, "output: ". output)

  " when called with "--with-colons" gpg encodes its output _ALWAYS_ as UTF-8,
  " so convert it, if necessary
  if (&encoding != "utf-8")
    let output = iconv(output, "utf-8", &encoding)
  endif
  let lines = split(output, "\n")

  " parse the output of gpg
  let pubseen = 0
  let counter = 0
  let gpgids = []
  let choices = "The name \"" . a:name . "\" is ambiguous. Please select the correct key:\n"
  for line in lines
    let fields = split(line, ":")
    " search for the next uid
    if (pubseen == 1)
      if (fields[0] == "uid")
        let choices = choices . "   " . fields[9] . "\n"
      else
        let pubseen = 0
      endif
    endif

    " search for the next pub
    if (pubseen == 0)
      if (fields[0] == "pub")
        let identity = fields[4]
        let gpgids += [identity]
        if exists("*strftime")
          let choices = choices . counter . ": ID: 0x" . identity . " created at " . strftime("%c", fields[5]) . "\n"
        else
          let choices = choices . counter . ": ID: 0x" . identity . "\n"
        endif
        let counter = counter+1
        let pubseen = 1
      endif
    endif

  endfor

  " counter > 1 means we have more than one results
  let answer = 0
  if (counter > 1)
    let choices = choices . "Enter number: "
    let answer = input(choices, "0")
    while (answer == "")
      let answer = input("Enter number: ", "0")
    endwhile
  endif

  call s:GPGDebug(3, "<<<<<<<< Leaving s:GPGIDToName()")
  return get(gpgids, answer, "")
endfunction

" Function: s:GPGIDToName(identity) {{{2
"
" find name corresponding to a GPG key ID
" Returns: Name for the given ID
"
function s:GPGIDToName(identity)
  call s:GPGDebug(3, ">>>>>>>> Entering s:GPGIDToName()")

  " TODO is the encryption subkey really unique?

  " ask gpg for the id for a name
  let commandline = s:GPGCommand . " --quiet --with-colons --fixed-list-mode --list-keys " . a:identity
  call s:GPGDebug(2, "command: ". commandline)
  let &shellredir = s:shellredir
  let &shell = s:shell
  let output = system(commandline)
  let &shellredir = s:shellredirsave
  let &shell = s:shellsave
  call s:GPGDebug(2, "output: ". output)

  " when called with "--with-colons" gpg encodes its output _ALWAYS_ as UTF-8,
  " so convert it, if necessary
  if (&encoding != "utf-8")
    let output = iconv(output, "utf-8", &encoding)
  endif
  let lines = split(output, "\n")

  " parse the output of gpg
  let pubseen = 0
  let uid = ""
  for line in lines
    let fields = split(line, ":")
    if (pubseen == 0) " search for the next pub
      if (fields[0] == "pub")
        let pubseen = 1
      endif
    else " search for the next uid
      if (fields[0] == "uid")
        let pubseen = 0
        if exists("*strftime")
          let uid = fields[9] . s:GPGMagicString . "(ID: 0x" . a:identity . " created at " . strftime("%c", fields[5]) . ")"
        else
          let uid = fields[9] . s:GPGMagicString . "(ID: 0x" . a:identity . ")"
        endif
        break
      endif
    endif
  endfor

  call s:GPGDebug(3, "<<<<<<<< Leaving s:GPGIDToName()")
  return uid
endfunction

" Function: s:GPGDebug(level, text) {{{2
"
" output debug message, if this message has high enough importance
" only define function if GPGDebugLevel set at all
"
function s:GPGDebug(level, text)
  if exists("g:GPGDebugLevel") && g:GPGDebugLevel >= a:level
    if exists("g:GPGDebugLog")
      execute "redir >> " . g:GPGDebugLog
      echom "GnuPG: " . a:text
      redir END
    else
      echom "GnuPG: " . a:text
    endif
  endif
endfunction

" Section: Commands {{{1

command! GPGViewRecipients call s:GPGViewRecipients()
command! GPGEditRecipients call s:GPGEditRecipients()
command! GPGViewOptions call s:GPGViewOptions()
command! GPGEditOptions call s:GPGEditOptions()

" Section: Menu {{{1

if (has("menu"))
  amenu <silent> Plugin.GnuPG.View\ Recipients :GPGViewRecipients<CR>
  amenu <silent> Plugin.GnuPG.Edit\ Recipients :GPGEditRecipients<CR>
  amenu <silent> Plugin.GnuPG.View\ Options :GPGViewOptions<CR>
  amenu <silent> Plugin.GnuPG.Edit\ Options :GPGEditOptions<CR>
endif

" vim600: set foldmethod=marker foldlevel=0 :
