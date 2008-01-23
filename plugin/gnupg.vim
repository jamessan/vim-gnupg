" Name: gnupg.vim
" Version:  $Id: gnupg.vim 1933 2008-01-23 09:49:33Z mbr $
" Author:   Markus Braun <markus.braun@krawel.de>
" Summary:  Vim plugin for transparent editing of gpg encrypted files.
" Licence:  This program is free software; you can redistribute it and/or
"           modify it under the terms of the GNU General Public License.
"           See http://www.gnu.org/copyleft/gpl.txt
" Section: Documentation {{{1
" Description:
"   
"   This script implements transparent editing of gpg encrypted files. The
"   filename must have a ".gpg", ".pgp" or ".asc" suffix. When opening such
"   a file the content is decrypted, when opening a new file the script will
"   ask for the recipients of the encrypted file. The file content will be
"   encrypted to all recipients before it is written. The script turns off
"   viminfo and swapfile to increase security.
"
" Installation: 
"
"   Copy the gnupg.vim file to the $HOME/.vim/plugin directory.
"   Refer to ':help add-plugin', ':help add-global-plugin' and ':help
"   runtimepath' for more details about Vim plugins.
"
" Commands:
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
" Variables:
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
" Credits:
"   Mathieu Clabaut for inspirations through his vimspell.vim script.
"   Richard Bronosky for patch to enable ".pgp" suffix.
"   Erik Remmelzwaal for patch to enable windows support and patient beta
"   testing.
"   Lars Becker for patch to make gpg2 working.
"
" Section: Plugin header {{{1
if (exists("g:loaded_gnupg") || &cp || exists("#BufReadPre#*.\(gpg\|asc\|pgp\)"))
  finish
endi
let g:loaded_gnupg = "$Revision: 1933 $"

" Section: Autocmd setup {{{1
augroup GnuPG
autocmd!

" initialize the internal variables
autocmd BufNewFile,BufReadPre,FileReadPre      *.\(gpg\|asc\|pgp\) call s:GPGInit()
" force the user to edit the recipient list if he opens a new file and public
" keys are preferred
autocmd BufNewFile                             *.\(gpg\|asc\|pgp\) if (exists("g:GPGPreferSymmetric") && g:GPGPreferSymmetric == 0) | call s:GPGEditRecipients() | endi
" do the decryption
autocmd BufReadPost,FileReadPost               *.\(gpg\|asc\|pgp\) call s:GPGDecrypt()

" convert all text to encrypted text before writing
autocmd BufWritePre,FileWritePre               *.\(gpg\|asc\|pgp\) call s:GPGEncrypt()
" undo the encryption so we are back in the normal text, directly
" after the file has been written.
autocmd BufWritePost,FileWritePost             *.\(gpg\|asc\|pgp\) call s:GPGEncryptPost()

augroup END

" Section: Highlight setup {{{1
highlight default link GPGWarning WarningMsg
highlight default link GPGError ErrorMsg
highlight default link GPGHighlightUnknownRecipient ErrorMsg

" Section: Functions {{{1
" Function: s:GPGInit() {{{2
"
" initialize the plugin
"
fun s:GPGInit()
  " first make sure nothing is written to ~/.viminfo while editing
  " an encrypted file.
  set viminfo=

  " we don't want a swap file, as it writes unencrypted data to disk
  set noswapfile

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

  " check if debugging is turned on
  if (!exists("g:GPGDebugLevel"))
    let g:GPGDebugLevel = 0
  endif
 
  " print version
  call s:GPGDebug(1, "gnupg.vim ". g:loaded_gnupg)

  " determine if gnupg can use the gpg-agent
  if (exists("$GPG_AGENT_INFO") && g:GPGUseAgent == 1)
    if (!exists("$GPG_TTY"))
      echohl GPGError
      echo "The GPG_TTY is not set!"
      echo "gpg-agent might not work."
      echohl None
    endif
    let s:GPGCommand="gpg --use-agent"
  else
    let s:GPGCommand="gpg --no-use-agent"
  endif

  " don't use tty in gvim
  " FIXME find a better way to avoid an error.
  "       with this solution only --use-agent will work
  if has("gui_running")
    let s:GPGCommand=s:GPGCommand . " --no-tty"
  endif

  " setup shell environment for unix and windows
  let s:shellredirsave=&shellredir
  let s:shellsave=&shell
  if (match(&shell,"\\(cmd\\|command\\).exe") >= 0)
    " windows specific settings
    let s:shellredir = '>%s'
    let s:shell = &shell
    let s:stderrredirnull = '2>nul'
  else
    " unix specific settings
    let s:shellredir = &shellredir
    let s:shell = 'sh'
    let s:stderrredirnull ='2>/dev/null'
    let s:GPGCommand="LANG=C LC_ALL=C " . s:GPGCommand
  endi

  " find the supported algorithms
  let &shellredir=s:shellredir
  let &shell=s:shell
  let output=system(s:GPGCommand . " --version")
  let &shellredir=s:shellredirsave
  let &shell=s:shellsave

  let s:GPGPubkey=substitute(output, ".*Pubkey: \\(.\\{-}\\)\n.*", "\\1", "")
  let s:GPGCipher=substitute(output, ".*Cipher: \\(.\\{-}\\)\n.*", "\\1", "")
  let s:GPGHash=substitute(output, ".*Hash: \\(.\\{-}\\)\n.*", "\\1", "")
  let s:GPGCompress=substitute(output, ".*Compress: \\(.\\{-}\\)\n.*", "\\1", "")
endf

" Function: s:GPGDecrypt() {{{2
"
" decrypt the buffer and find all recipients of the encrypted file
"
fun s:GPGDecrypt()
  " switch to binary mode to read the encrypted file
  set bin

  " get the filename of the current buffer
  let filename=escape(expand("%:p"), '\"')

  " clear GPGEncrypted, GPGRecipients, GPGUnknownRecipients and GPGOptions
  let b:GPGEncrypted=0
  let b:GPGRecipients=""
  let b:GPGUnknownRecipients=""
  let b:GPGOptions=""

  " find the recipients of the file
  let &shellredir=s:shellredir
  let &shell=s:shell
  let output=system(s:GPGCommand . " --verbose --decrypt --list-only --dry-run --batch --no-use-agent --logger-fd 1 \"" . filename . "\"")
  let &shellredir=s:shellredirsave
  let &shell=s:shellsave
  call s:GPGDebug(1, "output of command '" . s:GPGCommand . " --verbose --decrypt --list-only --dry-run --batch --no-use-agent --logger-fd 1 \"" . filename . "\"' is:")
  call s:GPGDebug(1, ">>>>> " . output . " <<<<<")

  " check if the file is symmetric/asymmetric encrypted
  if (match(output, "gpg: encrypted with [[:digit:]]\\+ passphrase") >= 0)
    " file is symmetric encrypted
    let b:GPGEncrypted=1
    call s:GPGDebug(1, "this file is symmetric encrypted")

    let b:GPGOptions=b:GPGOptions . "symmetric:"

    let cipher=substitute(output, ".*gpg: \\([^ ]\\+\\) encrypted data.*", "\\1", "")
    if (match(s:GPGCipher, "\\<" . cipher . "\\>") >= 0)
      let b:GPGOptions=b:GPGOptions . "cipher-algo " . cipher . ":"
      call s:GPGDebug(1, "cipher-algo is " . cipher)
    else
      echohl GPGWarning
      echo "The cipher " . cipher . " is not known by the local gpg command. Using default!"
      echo
      echohl None
    endi
  elseif (match(output, "gpg: public key is [[:xdigit:]]\\{8}") >= 0)
    " file is asymmetric encrypted
    let b:GPGEncrypted=1
    call s:GPGDebug(1, "this file is asymmetric encrypted")

    let b:GPGOptions=b:GPGOptions . "encrypt:"

    let start=match(output, "gpg: public key is [[:xdigit:]]\\{8}")
    while (start >= 0)
      let start=start + strlen("gpg: public key is ")
      let recipient=strpart(output, start, 8)
      call s:GPGDebug(1, "recipient is " . recipient)
      let name=s:GPGNameToID(recipient)
      if (strlen(name) > 0)
	let b:GPGRecipients=b:GPGRecipients . name . ":" 
        call s:GPGDebug(1, "name of recipient is " . name)
      else
	let b:GPGUnknownRecipients=b:GPGUnknownRecipients . recipient . ":" 
	echohl GPGWarning
	echo "The recipient " . recipient . " is not in your public keyring!"
	echohl None
      end
      let start=match(output, "gpg: public key is [[:xdigit:]]\\{8}", start)
    endw
  else
    " file is not encrypted
    let b:GPGEncrypted=0
    call s:GPGDebug(1, "this file is not encrypted")
    echohl GPGWarning
    echo "File is not encrypted, all GPG functions disabled!"
    echohl None
    set nobin
    return
  endi

  " check if the message is armored
  if (match(output, "gpg: armor header") >= 0)
    call s:GPGDebug(1, "this file is armored")
    let b:GPGOptions=b:GPGOptions . "armor:"
  endi

  " finally decrypt the buffer content
  " since even with the --quiet option passphrase typos will be reported,
  " we must redirect stderr (using shell temporarily)
  let &shellredir=s:shellredir
  let &shell=s:shell
  exec "'[,']!" . s:GPGCommand . " --quiet --decrypt " . s:stderrredirnull
  let &shellredir=s:shellredirsave
  let &shell=s:shellsave
  if (v:shell_error) " message could not be decrypted
    silent u
    echohl GPGError
    let asd=input("Message could not be decrypted! (Press ENTER)")
    echohl None
    bwipeout
    set nobin
    return
  endi

  " turn off binary mode
  set nobin

  " call the autocommand for the file minus .gpg$
  execute ":doautocmd BufReadPost " . escape(expand("%:r"), ' *?\"'."'")
  call s:GPGDebug(2, "called autocommand for " . escape(expand("%:r"), ' *?\"'."'"))

  " refresh screen
  redraw!
endf

" Function: s:GPGEncrypt() {{{2
"
" encrypts the buffer to all previous recipients
"
fun s:GPGEncrypt()
  " save window view
  let s:GPGWindowView = winsaveview()
  call s:GPGDebug(2, "saved window view " . string(s:GPGWindowView))

  " store encoding and switch to a safe one
  if &fileencoding != &encoding
    let s:GPGEncoding = &encoding
    let &encoding = &fileencoding
    call s:GPGDebug(2, "encoding was \"" . s:GPGEncoding . "\", switched to \"" . &encoding . "\"")
  else
    let s:GPGEncoding = ""
    call s:GPGDebug(2, "encoding and fileencoding are the same (\"" . &encoding . "\"), not switching")
  endi

  " switch buffer to binary mode
  set bin

  " guard for unencrypted files
  if (exists("b:GPGEncrypted") && b:GPGEncrypted == 0)
    echohl GPGWarning
    echo "File is not encrypted, all GPG functions disabled!"
    echohl None
    return
  endi

  let options=""
  let recipients=""
  let field=0

  " built list of options
  if (!exists("b:GPGOptions") || strlen(b:GPGOptions) == 0)
    if (exists("g:GPGPreferSymmetric") && g:GPGPreferSymmetric == 1)
      let b:GPGOptions="symmetric:"
    else
      let b:GPGOptions="encrypt:"
    endi
    if (exists("g:GPGPreferArmor") && g:GPGPreferArmor == 1)
      let b:GPGOptions=b:GPGOptions . "armor:"
    endi
    call s:GPGDebug(1, "no options set, so using default options: " . b:GPGOptions)
  endi
  let field=0
  let option=s:GetField(b:GPGOptions, ":", field)
  while (strlen(option))
    let options=options . " --" . option . " "
    let field=field+1
    let option=s:GetField(b:GPGOptions, ":", field)
  endw

  " check if there are unknown recipients and warn
  if (exists("b:GPGUnknownRecipients") && strlen(b:GPGUnknownRecipients) > 0)
    echohl GPGWarning
    echo "There are unknown recipients!!"
    echo "Please use GPGEditRecipients to correct!!"
    echo
    echohl None
    call s:GPGDebug(1, "unknown recipients are: " . b:GPGUnknownRecipients)
  endi

  " built list of recipients
  if (exists("b:GPGRecipients") && strlen(b:GPGRecipients) > 0)
    call s:GPGDebug(1, "recipients are: " . b:GPGRecipients)
    let field=0
    let gpgid=s:GetField(b:GPGRecipients, ":", field)
    while (strlen(gpgid))
      let recipients=recipients . " -r " . gpgid
      let field=field+1
      let gpgid=s:GetField(b:GPGRecipients, ":", field)
    endw
  else
    if (match(b:GPGOptions, "encrypt:") >= 0)
      echohl GPGError
      echo "There are no recipients!!"
      echo "Please use GPGEditRecipients to correct!!"
      echo
      echohl None
    endi
  endi

  " encrypt the buffer
  let &shellredir=s:shellredir
  let &shell=s:shell
  silent exec "'[,']!" . s:GPGCommand . " --quiet --no-encrypt-to " . options . recipients . " " . s:stderrredirnull
  let &shellredir=s:shellredirsave
  let &shell=s:shellsave
  call s:GPGDebug(1, "called gpg command is: " . "'[,']!" . s:GPGCommand . " --quiet --no-encrypt-to " . options . recipients . " " . s:stderrredirnull)
  if (v:shell_error) " message could not be encrypted
    silent u
    echohl GPGError
    let asd=input("Message could not be encrypted! File might be empty! (Press ENTER)")
    echohl None
    bwipeout
    return
  endi

endf

" Function: s:GPGEncryptPost() {{{2
"
" undo changes don by encrypt, after writing
"
fun s:GPGEncryptPost()

  if (exists("b:GPGEncrypted") && b:GPGEncrypted == 0)
    return
  endi

  " undo encryption of buffer content
  silent u

  " switch back from binary mode
  set nobin

  " restore encoding
  if s:GPGEncoding != ""
    let &encoding = s:GPGEncoding
    call s:GPGDebug(2, "restored encoding \"" . &encoding . "\"")
  endi

  " restore window view
  call winrestview(s:GPGWindowView)
  call s:GPGDebug(2, "restored window view" . string(s:GPGWindowView))

  " refresh screen
  redraw!
endf

" Function: s:GPGViewRecipients() {{{2
"
" echo the recipients
"
fun s:GPGViewRecipients()
  " guard for unencrypted files
  if (exists("b:GPGEncrypted") && b:GPGEncrypted == 0)
    echohl GPGWarning
    echo "File is not encrypted, all GPG functions disabled!"
    echohl None
    return
  endi

  if (exists("b:GPGRecipients"))
    echo 'This file has following recipients (Unknown recipients have a prepended "!"):'
    " echo the recipients
    let field=0
    let name=s:GetField(b:GPGRecipients, ":", field)
    while (strlen(name) > 0)
      let name=s:GPGIDToName(name)
      echo name

      let field=field+1
      let name=s:GetField(b:GPGRecipients, ":", field)
    endw

    " put the unknown recipients in the scratch buffer
    let field=0
    echohl GPGWarning
    let name=s:GetField(b:GPGUnknownRecipients, ":", field)
    while (strlen(name) > 0)
      let name="!" . name
      echo name

      let field=field+1
      let name=s:GetField(b:GPGUnknownRecipients, ":", field)
    endw
    echohl None

    " check if there is any known recipient
    if (strlen(s:GetField(b:GPGRecipients, ":", 0)) == 0)
      echohl GPGError
      echo 'There are no known recipients!'
      echohl None
    endi
  endi
endf

" Function: s:GPGEditRecipients() {{{2
"
" create a scratch buffer with all recipients to add/remove recipients
"
fun s:GPGEditRecipients()
  " guard for unencrypted files
  if (exists("b:GPGEncrypted") && b:GPGEncrypted == 0)
    echohl GPGWarning
    echo "File is not encrypted, all GPG functions disabled!"
    echohl None
    return
  endi

  " only do this if it isn't already a GPGRecipients_* buffer
  if (match(bufname("%"), "^\\(GPGRecipients_\\|GPGOptions_\\)") != 0 && match(bufname("%"), "\.\\(gpg\\|asc\\|pgp\\)$") >= 0)

    " save buffer name
    let buffername=bufname("%")
    let editbuffername="GPGRecipients_" . buffername

    " check if this buffer exists
    if (!bufexists(editbuffername))
      " create scratch buffer
      exe 'silent! split ' . escape(editbuffername, ' *?\"'."'")

      " add a autocommand to regenerate the recipients after a write
      autocmd BufHidden,BufUnload <buffer> call s:GPGFinishRecipientsBuffer()
    else
      if (bufwinnr(editbuffername) >= 0)
	" switch to scratch buffer window
	exe 'silent! ' . bufwinnr(editbuffername) . "wincmd w"
      else
	" split scratch buffer window
        exe 'silent! sbuffer ' . escape(editbuffername, ' *?\"'."'")

	" add a autocommand to regenerate the recipients after a write
	autocmd BufHidden,BufUnload <buffer> call s:GPGFinishRecipientsBuffer()
      endi

      " empty the buffer
      silent normal! 1GdG
    endi

    " Mark the buffer as a scratch buffer
    setlocal buftype=nofile
    setlocal noswapfile
    setlocal nowrap
    setlocal nobuflisted
    setlocal nonumber

    " so we know for which other buffer this edit buffer is
    let b:corresponding_to=buffername

    " put some comments to the scratch buffer
    silent put ='GPG: ----------------------------------------------------------------------'
    silent put ='GPG: Please edit the list of recipients, one recipient per line'
    silent put ='GPG: Unknown recipients have a prepended \"!\"'
    silent put ='GPG: Lines beginning with \"GPG:\" are removed automatically'
    silent put ='GPG: Closing this buffer commits changes'
    silent put ='GPG: ----------------------------------------------------------------------'

    " put the recipients in the scratch buffer
    let recipients=getbufvar(b:corresponding_to, "GPGRecipients")
    let field=0

    let name=s:GetField(recipients, ":", field)
    while (strlen(name) > 0)
      let name=s:GPGIDToName(name)
      silent put =name

      let field=field+1
      let name=s:GetField(recipients, ":", field)
    endw

    " put the unknown recipients in the scratch buffer
    let unknownRecipients=getbufvar(b:corresponding_to, "GPGUnknownRecipients")
    let field=0
    let syntaxPattern="\\(nonexistingwordinthisbuffer"

    let name=s:GetField(unknownRecipients, ":", field)
    while (strlen(name) > 0)
      let name="!" . name
      let syntaxPattern=syntaxPattern . "\\|" . name
      silent put =name

      let field=field+1
      let name=s:GetField(unknownRecipients, ":", field)
    endw

    let syntaxPattern=syntaxPattern . "\\)"

    " define highlight
    if (has("syntax") && exists("g:syntax_on"))
      exec('syntax match GPGUnknownRecipient    "' . syntaxPattern . '"')
      highlight clear GPGUnknownRecipient
      highlight link GPGUnknownRecipient  GPGHighlightUnknownRecipient

      syntax match GPGComment "^GPG:.*$"
      highlight clear GPGComment
      highlight link GPGComment Comment
    endi

    " delete the empty first line
    silent normal! 1Gdd

    " jump to the first recipient
    silent normal! G

  endi
endf

" Function: s:GPGFinishRecipientsBuffer() {{{2
"
" create a new recipient list from RecipientsBuffer
fun s:GPGFinishRecipientsBuffer()
  " guard for unencrypted files
  if (exists("b:GPGEncrypted") && b:GPGEncrypted == 0)
    echohl GPGWarning
    echo "File is not encrypted, all GPG functions disabled!"
    echohl None
    return
  endi

  " go to buffer before doing work
  if (bufnr("%") != expand("<abuf>"))
    " switch to scratch buffer window
    exe 'silent! ' . bufwinnr(expand("<afile>")) . "wincmd w"
  endi

  " clear GPGRecipients and GPGUnknownRecipients
  let GPGRecipients=""
  let GPGUnknownRecipients=""

  " delete the autocommand
  autocmd! * <buffer>

  let currentline=1
  let recipient=getline(currentline)

  " get the recipients from the scratch buffer
  while (currentline <= line("$"))
    " delete all spaces at beginning and end of the line
    " also delete a '!' at the beginning of the line
    let recipient=substitute(recipient, "^[[:space:]!]*\\(.\\{-}\\)[[:space:]]*$", "\\1", "")
    " delete comment lines
    let recipient=substitute(recipient, "^GPG:.*$", "", "")

    " only do this if the line is not empty
    if (strlen(recipient) > 0)
      let gpgid=s:GPGNameToID(recipient)
      if (strlen(gpgid) > 0)
	let GPGRecipients=GPGRecipients . gpgid . ":" 
      else
	let GPGUnknownRecipients=GPGUnknownRecipients . recipient . ":"
	echohl GPGWarning
	echo "The recipient " . recipient . " is not in your public keyring!"
	echohl None
      end
    endi

    let currentline=currentline+1
    let recipient=getline(currentline)
  endw

  " write back the new recipient list to the corresponding buffer and mark it
  " as modified. Buffer is now for sure a encrypted buffer.
  call setbufvar(b:corresponding_to, "GPGRecipients", GPGRecipients)
  call setbufvar(b:corresponding_to, "GPGUnknownRecipients", GPGUnknownRecipients)
  call setbufvar(b:corresponding_to, "&mod", 1)
  call setbufvar(b:corresponding_to, "GPGEncrypted", 1)

  " check if there is any known recipient
  if (strlen(s:GetField(GPGRecipients, ":", 0)) == 0)
    echohl GPGError
    echo 'There are no known recipients!'
    echohl None
  endi
endf

" Function: s:GPGViewOptions() {{{2
"
" echo the recipients
"
fun s:GPGViewOptions()
  " guard for unencrypted files
  if (exists("b:GPGEncrypted") && b:GPGEncrypted == 0)
    echohl GPGWarning
    echo "File is not encrypted, all GPG functions disabled!"
    echohl None
    return
  endi

  if (exists("b:GPGOptions"))
    echo 'This file has following options:'
    " echo the options
    let field=0
    let option=s:GetField(b:GPGOptions, ":", field)
    while (strlen(option) > 0)
      echo option

      let field=field+1
      let option=s:GetField(b:GPGOptions, ":", field)
    endw
  endi
endf

" Function: s:GPGEditOptions() {{{2
"
" create a scratch buffer with all recipients to add/remove recipients
"
fun s:GPGEditOptions()
  " guard for unencrypted files
  if (exists("b:GPGEncrypted") && b:GPGEncrypted == 0)
    echohl GPGWarning
    echo "File is not encrypted, all GPG functions disabled!"
    echohl None
    return
  endi

  " only do this if it isn't already a GPGOptions_* buffer
  if (match(bufname("%"), "^\\(GPGRecipients_\\|GPGOptions_\\)") != 0 && match(bufname("%"), "\.\\(gpg\\|asc\\|pgp\\)$") >= 0)

    " save buffer name
    let buffername=bufname("%")
    let editbuffername="GPGOptions_" . buffername

    " check if this buffer exists
    if (!bufexists(editbuffername))
      " create scratch buffer
      exe 'silent! split ' . escape(editbuffername, ' *?\"'."'")

      " add a autocommand to regenerate the options after a write
      autocmd BufHidden,BufUnload <buffer> call s:GPGFinishOptionsBuffer()
    else
      if (bufwinnr(editbuffername) >= 0)
	" switch to scratch buffer window
	exe 'silent! ' . bufwinnr(editbuffername) . "wincmd w"
      else
	" split scratch buffer window
        exe 'silent! sbuffer ' . escape(editbuffername, ' *?\"'."'")

	" add a autocommand to regenerate the options after a write
	autocmd BufHidden,BufUnload <buffer> call s:GPGFinishOptionsBuffer()
      endi

      " empty the buffer
      silent normal! 1GdG
    endi

    " Mark the buffer as a scratch buffer
    setlocal buftype=nofile
    setlocal noswapfile
    setlocal nowrap
    setlocal nobuflisted
    setlocal nonumber

    " so we know for which other buffer this edit buffer is
    let b:corresponding_to=buffername

    " put some comments to the scratch buffer
    silent put ='GPG: ----------------------------------------------------------------------'
    silent put ='GPG: THERE IS NO CHECK OF THE ENTERED OPTIONS!'
    silent put ='GPG: YOU NEED TO KNOW WHAT YOU ARE DOING!'
    silent put ='GPG: IF IN DOUBT, QUICKLY EXIT USING :x OR :bd'
    silent put ='GPG: Please edit the list of options, one option per line'
    silent put ='GPG: Please refer to the gpg documentation for valid options'
    silent put ='GPG: Lines beginning with \"GPG:\" are removed automatically'
    silent put ='GPG: Closing this buffer commits changes'
    silent put ='GPG: ----------------------------------------------------------------------'

    " put the options in the scratch buffer
    let options=getbufvar(b:corresponding_to, "GPGOptions")
    let field=0

    let option=s:GetField(options, ":", field)
    while (strlen(option) > 0)
      silent put =option

      let field=field+1
      let option=s:GetField(options, ":", field)
    endw

    " delete the empty first line
    silent normal! 1Gdd

    " jump to the first option
    silent normal! G

    " define highlight
    if (has("syntax") && exists("g:syntax_on"))
      syntax match GPGComment "^GPG:.*$"
      highlight clear GPGComment
      highlight link GPGComment Comment
    endi
  endi
endf

" Function: s:GPGFinishOptionsBuffer() {{{2
"
" create a new option list from OptionsBuffer
fun s:GPGFinishOptionsBuffer()
  " guard for unencrypted files
  if (exists("b:GPGEncrypted") && b:GPGEncrypted == 0)
    echohl GPGWarning
    echo "File is not encrypted, all GPG functions disabled!"
    echohl None
    return
  endi

  " go to buffer before doing work
  if (bufnr("%") != expand("<abuf>"))
    " switch to scratch buffer window
    exe 'silent! ' . bufwinnr(expand("<afile>")) . "wincmd w"
  endi

  " clear GPGOptions and GPGUnknownOptions
  let GPGOptions=""
  let GPGUnknownOptions=""

  " delete the autocommand
  autocmd! * <buffer>

  let currentline=1
  let option=getline(currentline)

  " get the options from the scratch buffer
  while (currentline <= line("$"))
    " delete all spaces at beginning and end of the line
    " also delete a '!' at the beginning of the line
    let option=substitute(option, "^[[:space:]!]*\\(.\\{-}\\)[[:space:]]*$", "\\1", "")
    " delete comment lines
    let option=substitute(option, "^GPG:.*$", "", "")

    " only do this if the line is not empty
    if (strlen(option) > 0)
      let GPGOptions=GPGOptions . option . ":" 
    endi

    let currentline=currentline+1
    let option=getline(currentline)
  endw

  " write back the new option list to the corresponding buffer and mark it
  " as modified
  call setbufvar(b:corresponding_to, "GPGOptions", GPGOptions)
  call setbufvar(b:corresponding_to, "&mod", 1)

endf

" Function: s:GPGNameToID(name) {{{2
"
" find GPG key ID corresponding to a name
" Returns: ID for the given name
fun s:GPGNameToID(name)
  " ask gpg for the id for a name
  let &shellredir=s:shellredir
  let &shell=s:shell
  let output=system(s:GPGCommand . " --quiet --with-colons --fixed-list-mode --list-keys \"" . a:name . "\"")
  let &shellredir=s:shellredirsave
  let &shell=s:shellsave

  " parse the output of gpg
  let pub_seen=0
  let uid_seen=0
  let line=0
  let counter=0
  let gpgids=""
  let choices="The name \"" . a:name . "\" is ambiguous. Please select the correct key:\n"
  let linecontent=s:GetField(output, "\n", line)
  while (strlen(linecontent))
    " search for the next uid
    if (pub_seen == 1)
      if (s:GetField(linecontent, ":", 0) == "uid")
	if (uid_seen == 0)
	  let choices=choices . counter . ": " . s:GetField(linecontent, ":", 9) . "\n"
	  let counter=counter+1
	  let uid_seen=1
	else
	  let choices=choices . "   " . s:GetField(linecontent, ":", 9) . "\n"
	endi
      else
	let uid_seen=0
	let pub_seen=0
      endi
    endi

    " search for the next pub
    if (pub_seen == 0)
      if (s:GetField(linecontent, ":", 0) == "pub")
	let gpgids=gpgids . s:GetField(linecontent, ":", 4) . ":"
	let pub_seen=1
      endi
    endi

    let line=line+1
    let linecontent=s:GetField(output, "\n", line)
  endw

  " counter > 1 means we have more than one results
  let answer=0
  if (counter > 1)
    let choices=choices . "Enter number: "
    let answer=input(choices, "0")
    while (answer == "")
      let answer=input("Enter number: ", "0")
    endw
  endi

  return s:GetField(gpgids, ":", answer)
endf

" Function: s:GPGIDToName(identity) {{{2
"
" find name corresponding to a GPG key ID
" Returns: Name for the given ID
fun s:GPGIDToName(identity)
  " TODO is the encryption subkey really unique?

  " ask gpg for the id for a name
  let &shellredir=s:shellredir
  let &shell=s:shell
  let output=system(s:GPGCommand . " --quiet --with-colons --fixed-list-mode --list-keys " . a:identity )
  let &shellredir=s:shellredirsave
  let &shell=s:shellsave

  " parse the output of gpg
  let pub_seen=0
  let finish=0
  let line=0
  let linecontent=s:GetField(output, "\n", line)
  while (strlen(linecontent) && !finish)
    if (pub_seen == 0) " search for the next pub
      if (s:GetField(linecontent, ":", 0) == "pub")
	let pub_seen=1
      endi
    else " search for the next uid
      if (s:GetField(linecontent, ":", 0) == "uid")
	let pub_seen=0
	let finish=1
	let uid=s:GetField(linecontent, ":", 9)
      endi
    endi

    let line=line+1
    let linecontent=s:GetField(output, "\n", line)
  endw

  return uid
endf

" Function: s:GetField(line, separator, field) {{{2
"
" find field of 'separator' separated string, counting starts with 0
" Returns: content of the field, if field doesn't exist it returns an empty
"          string
fun s:GetField(line, separator, field)
  let counter=a:field
  let separatorLength=strlen(a:separator)
  let start=0
  let end=match(a:line, a:separator)
  if (end < 0)
    let end=strlen(a:line)
  endi

  " search for requested field
  while (start < strlen(a:line) && counter > 0)
    let counter=counter-separatorLength
    let start=end+separatorLength
    let end=match(a:line, a:separator, start)
    if (end < 0)
      let end=strlen(a:line)
    endi
  endw

  if (start < strlen(a:line))
    return strpart(a:line, start, end-start)
  else
    return ""
  endi
endf

" Function: s:GPGDebug(level, text) {{{2
"
" output debug message, if this message has high enough importance
fun s:GPGDebug(level, text)
  if (g:GPGDebugLevel >= a:level)
    echom a:text
  endi
endf

" Section: Command definitions {{{1
com! GPGViewRecipients call s:GPGViewRecipients()
com! GPGEditRecipients call s:GPGEditRecipients()
com! GPGViewOptions call s:GPGViewOptions()
com! GPGEditOptions call s:GPGEditOptions()

" vim600: foldmethod=marker:foldlevel=0
