" Name:    autoload/gnupg.vim
" Last Change: 2017 Feb 25
" Summary: Autoload functions for the gnupg plugin.
" License: This program is free software; you can redistribute it and/or
"          modify it under the terms of the GNU General Public License
"          as published by the Free Software Foundation; either version
"          2 of the License, or (at your option) any later version.
"          See http://www.gnu.org/copyleft/gpl-2.0.txt

" Section: Variables {{{1
let s:InitRun = 0

" Section: Constants {{{1

let s:MagicString = "\t \t"
let s:keyPattern = '\%(0x\)\=[[:xdigit:]]\{8,16}'

" Section: Public functions {{{1

" Function: gnupg#init(bufread) {{{2
"
" initialize the plugin
" The bufread argument specifies whether this was called due to BufReadCmd
"
function gnupg#init(bufread)
  call s:Debug(3, printf(">>>>>>>> Entering gnupg#init(%d)", a:bufread))

  " For FileReadCmd, we're reading the contents into another buffer.  If that
  " buffer is also destined to be encrypted, then these settings will have
  " already been set, otherwise don't set them since it limits the
  " functionality of the cleartext buffer.
  if a:bufread
    " we don't want a swap file, as it writes unencrypted data to disk
    setl noswapfile

    " if persistent undo is present, disable it for this buffer
    if exists('+undofile')
      setl noundofile
    endif

    " first make sure nothing is written to ~/.viminfo while editing
    " an encrypted file.
    set viminfo=
  endif

  " the rest only has to be run once
  if s:InitRun
    return
  endif

  " check what gpg command to use
  if (!exists("g:GPGExecutable"))
    if executable("gpg")
      let g:GPGExecutable = "gpg --trust-model always"
    else
      let g:GPGExecutable = "gpg2 --trust-model always"
    endif
  endif

  " check if gpg-agent is allowed
  if (!exists("g:GPGUseAgent"))
    let g:GPGUseAgent = 1
  endif

  " check if symmetric encryption is preferred
  if (!exists("g:GPGPreferSymmetric"))
    let g:GPGPreferSymmetric = 0
  endif

  " check if signed files are preferred
  if (!exists("g:GPGPreferSign"))
    let g:GPGPreferSign = 0
  endif

  " start with empty default recipients if none is defined so far
  if (!exists("g:GPGDefaultRecipients"))
    let g:GPGDefaultRecipients = []
  endif

  if (!exists("g:GPGPossibleRecipients"))
    let g:GPGPossibleRecipients = []
  endif


  " prefer not to use pipes since it can garble gpg agent display
  if (!exists("g:GPGUsePipes"))
    let g:GPGUsePipes = 0
  endif

  " allow alternate gnupg homedir
  if (!exists('g:GPGHomedir'))
    let g:GPGHomedir = ''
  endif

  " print version
  call s:Debug(1, "gnupg.vim ". g:loaded_gnupg)

  let s:Command = g:GPGExecutable

  " don't use tty in gvim except for windows: we get their a tty for free.
  " FIXME find a better way to avoid an error.
  "       with this solution only --use-agent will work
  if (has("gui_running") && !has("gui_win32"))
    let s:Command .= " --no-tty"
  endif

  " setup shell environment for unix and windows
  let s:shellredirsave = &shellredir
  let s:shellsave = &shell
  let s:shelltempsave = &shelltemp
  " noshelltemp isn't currently supported on Windows, but it doesn't cause any
  " errors and this future proofs us against requiring changes if Windows
  " gains noshelltemp functionality
  let s:shelltemp = !g:GPGUsePipes
  if (has("unix"))
    " unix specific settings
    let s:shellredir = ">%s 2>&1"
    let s:shell = '/bin/sh'
    let s:stderrredirnull = '2>/dev/null'
  else
    " windows specific settings
    let s:shellredir = '>%s'
    let s:shell = &shell
    let s:stderrredirnull = '2>nul'
  endif

  call s:Debug(3, "shellredirsave: " . s:shellredirsave)
  call s:Debug(3, "shellsave: " . s:shellsave)
  call s:Debug(3, "shelltempsave: " . s:shelltempsave)

  call s:Debug(3, "shell: " . s:shell)
  call s:Debug(3, "shellcmdflag: " . &shellcmdflag)
  call s:Debug(3, "shellxquote: " . &shellxquote)
  call s:Debug(3, "shellredir: " . s:shellredir)
  call s:Debug(3, "stderrredirnull: " . s:stderrredirnull)

  call s:Debug(3, "shell implementation: " . resolve(s:shell))

  " find the supported algorithms
  let output = s:System({ 'level': 2, 'args': '--version' })

  let gpgversion = substitute(output, '^gpg (GnuPG) \([0-9]\+\.\d\+\).*', '\1', '')
  let s:Pubkey = substitute(output, ".*Pubkey: \\(.\\{-}\\)\n.*", "\\1", "")
  let s:Cipher = substitute(output, ".*Cipher: \\(.\\{-}\\)\n.*", "\\1", "")
  let s:Hash = substitute(output, ".*Hash: \\(.\\{-}\\)\n.*", "\\1", "")
  let s:Compress = substitute(output, ".*Compress.\\{-}: \\(.\\{-}\\)\n.*", "\\1", "")

  " determine if gnupg can use the gpg-agent
  if (str2float(gpgversion) >= 2.1 || (exists("$GPG_AGENT_INFO") && g:GPGUseAgent == 1))
    if (!exists("$GPG_TTY") && !has("gui_running"))
      " Need to determine the associated tty by running a command in the
      " shell.  We can't use system() here because that doesn't run in a shell
      " connected to a tty, so it's rather useless.
      "
      " Save/restore &modified so the buffer isn't incorrectly marked as
      " modified just by detecting the correct tty value.
      " Do the &undolevels dance so the :read and :delete don't get added into
      " the undo tree, as the user needn't be aware of these.
      let [mod, levels] = [&l:modified, &undolevels]
      set undolevels=-1
      silent read !tty
      let $GPG_TTY = getline('.')
      silent delete
      let [&l:modified, &undolevels] = [mod, levels]
      " redraw is needed since we're using silent to run !tty, c.f. :help :!
      redraw!
      if (v:shell_error)
        let $GPG_TTY = ""
        echohl GPGWarning
        echom "$GPG_TTY is not set and the `tty` command failed! gpg-agent might not work."
        echohl None
      endif
    endif
    let s:Command .= " --use-agent"
  else
    let s:Command .= " --no-use-agent"
  endif

  call s:Debug(2, "public key algorithms: " . s:Pubkey)
  call s:Debug(2, "cipher algorithms: " . s:Cipher)
  call s:Debug(2, "hashing algorithms: " . s:Hash)
  call s:Debug(2, "compression algorithms: " . s:Compress)
  call s:Debug(3, "<<<<<<<< Leaving gnupg#init()")
  let s:InitRun = 1
endfunction

" Function: gnupg#decrypt(bufread) {{{2
"
" decrypt the buffer and find all recipients of the encrypted file
" The bufread argument specifies whether this was called due to BufReadCmd
"
function gnupg#decrypt(bufread)
  call s:Debug(3, printf(">>>>>>>> Entering gnupg#decrypt(%d)", a:bufread))

  " get the filename of the current buffer
  let filename = expand("<afile>:p")

  " clear GPGRecipients and GPGOptions
  if type(g:GPGDefaultRecipients) == type([])
    let b:GPGRecipients = copy(g:GPGDefaultRecipients)
  else
    let b:GPGRecipients = []
    echohl GPGWarning
    echom "g:GPGDefaultRecipients is not a Vim list, please correct this in your vimrc!"
    echohl None
  endif
  let b:GPGOptions = []

  " file name minus extension
  let autocmd_filename = expand('<afile>:r')

  " File doesn't exist yet, so nothing to decrypt
  if !filereadable(filename)
    " Allow the user to define actions for GnuPG buffers
    silent doautocmd User GnuPG
    silent execute ':doautocmd BufNewFile ' . fnameescape(autocmd_filename)
    call s:Debug(2, 'called BufNewFile autocommand for ' . autocmd_filename)

    " This is a new file, so force the user to edit the recipient list if
    " they open a new file and public keys are preferred
    if (g:GPGPreferSymmetric == 0)
        call gnupg#edit_recipients()
    endif

    return
  endif

  " Only let this if the file actually exists, otherwise GPG functionality
  " will be disabled when editing a buffer that doesn't yet have a backing
  " file
  let b:GPGEncrypted = 0

  " find the recipients of the file
  let cmd = { 'level': 3 }
  let cmd.args = '--verbose --decrypt --list-only --dry-run --no-use-agent --logger-fd 1 ' . s:shellescape(filename)
  let output = s:System(cmd)

  " Suppress the "N more lines" message when editing a file, not when reading
  " the contents of a file into a buffer
  let silent = a:bufread ? 'silent ' : ''

  let asymmPattern = 'gpg: public key is ' . s:keyPattern
  " check if the file is symmetric/asymmetric encrypted
  if (match(output, "gpg: encrypted with [[:digit:]]\\+ passphrase") >= 0)
    " file is symmetric encrypted
    let b:GPGEncrypted = 1
    call s:Debug(1, "this file is symmetric encrypted")

    let b:GPGOptions += ["symmetric"]

    " find the used cipher algorithm
    let cipher = substitute(output, ".*gpg: \\([^ ]\\+\\) encrypted data.*", "\\1", "")
    if (match(s:Cipher, "\\<" . cipher . "\\>") >= 0)
      let b:GPGOptions += ["cipher-algo " . cipher]
      call s:Debug(1, "cipher-algo is " . cipher)
    else
      echohl GPGWarning
      echom "The cipher " . cipher . " is not known by the local gpg command. Using default!"
      echo
      echohl None
    endif
  elseif (match(output, asymmPattern) >= 0)
    " file is asymmetric encrypted
    let b:GPGEncrypted = 1
    call s:Debug(1, "this file is asymmetric encrypted")

    let b:GPGOptions += ["encrypt"]

    " find the used public keys
    let start = match(output, asymmPattern)
    while (start >= 0)
      let start = start + strlen("gpg: public key is ")
      let recipient = matchstr(output, s:keyPattern, start)
      call s:Debug(1, "recipient is " . recipient)
      " In order to support anonymous communication, GnuPG allows eliding
      " information in the encryption metadata specifying what keys the file
      " was encrypted to (c.f., --throw-keyids and --hidden-recipient).  In
      " that case, the recipient(s) will be listed as having used a key of all
      " zeroes.
      " Since this will obviously never actually be in a keyring, only try to
      " convert to an ID or add to the recipients list if it's not a hidden
      " recipient.
      if recipient !~? '^0x0\+$'
        let name = s:NameToID(recipient)
        if !empty(name)
          let b:GPGRecipients += [name]
          call s:Debug(1, "name of recipient is " . name)
        else
          let b:GPGRecipients += [recipient]
          echohl GPGWarning
          echom "The recipient \"" . recipient . "\" is not in your public keyring!"
          echohl None
        end
      end
      let start = match(output, asymmPattern, start)
    endwhile
  else
    " file is not encrypted
    let b:GPGEncrypted = 0
    call s:Debug(1, "this file is not encrypted")
    echohl GPGWarning
    echom "File is not encrypted, all GPG functions disabled!"
    echohl None
  endif

  let bufname = b:GPGEncrypted ? autocmd_filename : filename
  if a:bufread
    silent execute ':doautocmd BufReadPre ' . fnameescape(bufname)
    call s:Debug(2, 'called BufReadPre autocommand for ' . bufname)
  else
    silent execute ':doautocmd FileReadPre ' . fnameescape(bufname)
    call s:Debug(2, 'called FileReadPre autocommand for ' . bufname)
  endif

  if b:GPGEncrypted
    " check if the message is armored
    if (match(output, "gpg: armor header") >= 0)
      call s:Debug(1, "this file is armored")
      let b:GPGOptions += ["armor"]
    endif

    " finally decrypt the buffer content
    " since even with the --quiet option passphrase typos will be reported,
    " we must redirect stderr (using shell temporarily)
    call s:Debug(1, "decrypting file")
    let cmd = { 'level': 1, 'ex': silent . 'read ++edit !' }
    let cmd.args = '--quiet --decrypt ' . s:shellescape(filename, 1)
    call s:Execute(cmd)

    if (v:shell_error) " message could not be decrypted
      echohl GPGError
      let blackhole = input("Message could not be decrypted! (Press ENTER)")
      echohl None
      " Only wipeout the buffer if we were creating one to start with.
      " FileReadCmd just reads the content into the existing buffer
      if a:bufread
        silent bwipeout!
      endif
      call s:GPGDebug(3, "<<<<<<<< Leaving s:GPGDecrypt()")
      return
    endif
    " Ensure the buffer is only saved by using our BufWriteCmd
    set buftype=acwrite
  else
    execute silent 'read' fnameescape(filename)
  endif

  if a:bufread
    " In order to make :undo a no-op immediately after the buffer is read,
    " we need to do this dance with 'undolevels'.  Actually discarding the undo
    " history requires performing a change after setting 'undolevels' to -1 and,
    " luckily, we have one we need to do (delete the extra line from the :r
    " command)
    let levels = &undolevels
    set undolevels=-1
    " :lockmarks doesn't actually prevent '[,'] from being overwritten, so we
    " need to manually set them ourselves instead
    silent 1delete
    1mark [
    $mark ]
    let &undolevels = levels
    " The buffer should be readonly if
    " - 'readonly' is already set (e.g., when using view/vim -R)
    " - permissions don't allow writing
    let &readonly = &readonly || (filereadable(filename) && filewritable(filename) == 0)
    silent execute ':doautocmd BufReadPost ' . fnameescape(bufname)
    call s:Debug(2, 'called BufReadPost autocommand for ' . bufname)
  else
    silent execute ':doautocmd FileReadPost ' . fnameescape(bufname)
    call s:Debug(2, 'called FileReadPost autocommand for ' . bufname)
  endif

  if b:GPGEncrypted
    " Allow the user to define actions for GnuPG buffers
    silent doautocmd User GnuPG

    " refresh screen
    redraw!
  endif

  call s:Debug(3, "<<<<<<<< Leaving gnupg#decrypt()")
endfunction

" Function: gnupg#encrypt() {{{2
"
" encrypts the buffer to all previous recipients
"
function gnupg#encrypt()
  call s:Debug(3, ">>>>>>>> Entering gnupg#encrypt()")

  " FileWriteCmd is only called when a portion of a buffer is being written to
  " disk.  Since Vim always sets the '[,'] marks to the part of a buffer that
  " is being written, that can be used to determine whether BufWriteCmd or
  " FileWriteCmd triggered us.
  if [line("'["), line("']")] == [1, line('$')]
    let auType = 'BufWrite'
  else
    let auType = 'FileWrite'
  endif

  " file name minus extension
  let autocmd_filename = expand('<afile>:r')

  silent exe ':doautocmd '. auType .'Pre '. fnameescape(autocmd_filename)
  call s:Debug(2, 'called '. auType .'Pre autocommand for ' . autocmd_filename)

  " guard for unencrypted files
  if (exists("b:GPGEncrypted") && b:GPGEncrypted == 0)
    echohl GPGError
    let blackhole = input("Message could not be encrypted! (Press ENTER)")
    echohl None
    call s:Debug(3, "<<<<<<<< Leaving gnupg#encrypt()")
    return
  endif

  let filename = resolve(expand('<afile>'))
  " initialize GPGOptions if not happened before
  if (!exists("b:GPGOptions") || empty(b:GPGOptions))
    let b:GPGOptions = []
    if (exists("g:GPGPreferSymmetric") && g:GPGPreferSymmetric == 1)
      let b:GPGOptions += ["symmetric"]
      let b:GPGRecipients = []
    else
      let b:GPGOptions += ["encrypt"]
    endif
    " Fallback to preference by filename if the user didn't indicate
    " their preference.
    let preferArmor = get(g:, 'GPGPreferArmor', -1)
    if (preferArmor >= 0 && preferArmor) || filename =~ '\.asc$'
      let b:GPGOptions += ["armor"]
    endif
    if (exists("g:GPGPreferSign") && g:GPGPreferSign == 1)
      let b:GPGOptions += ["sign"]
    endif
    call s:Debug(1, "no options set, so using default options: " . string(b:GPGOptions))
  endif

  " built list of options
  let options = ""
  for option in b:GPGOptions
    let options = options . " --" . option . " "
  endfor

  if (!exists('b:GPGRecipients'))
    let b:GPGRecipients = []
  endif

  " check here again if all recipients are available in the keyring
  let recipients = s:CheckRecipients(b:GPGRecipients)

  " check if there are unknown recipients and warn
  if !empty(recipients.unknown)
    echohl GPGWarning
    echom "Please use GPGEditRecipients to correct!!"
    echo
    echohl None

    " Let user know whats happend and copy known_recipients back to buffer
    let dummy = input("Press ENTER to quit")
  endif

  " built list of recipients
  let options .= ' ' . join(map(recipients.valid, '"-r ".v:val'), ' ')

  " encrypt the buffer
  let destfile = tempname()
  let cmd = { 'level': 1, 'ex': "'[,']write !" }
  let cmd.args = '--quiet --no-encrypt-to ' . options
  let cmd.redirect = '>' . s:shellescape(destfile, 1)
  silent call s:Execute(cmd)

  if (v:shell_error) " message could not be encrypted
    " Command failed, so clean up the tempfile
    call delete(destfile)
    echohl GPGError
    let blackhole = input("Message could not be encrypted! (Press ENTER)")
    echohl None
    call s:Debug(3, "<<<<<<<< Leaving gnupg#encrypt()")
    return
  endif

  if rename(destfile, filename)
    " Rename failed, so clean up the tempfile
    call delete(destfile)
    echohl GPGError
    echom printf("\"%s\" E212: Can't open file for writing", filename)
    echohl None
    return
  endif

  if auType == 'BufWrite'
    setl nomodified
    let &readonly = filereadable(filename) && filewritable(filename) == 0
  endif

  silent exe ':doautocmd '. auType .'Post '. fnameescape(autocmd_filename)
  call s:Debug(2, 'called '. auType .'Post autocommand for ' . autocmd_filename)

  call s:Debug(3, "<<<<<<<< Leaving gnupg#encrypt()")
endfunction

" Function: gnupg#view_recipients() {{{2
"
" echo the recipients
"
function gnupg#view_recipients()
  call s:Debug(3, ">>>>>>>> Entering gnupg#view_recipients()")

  " guard for unencrypted files
  if (exists("b:GPGEncrypted") && b:GPGEncrypted == 0)
    echohl GPGWarning
    echom "File is not encrypted, all GPG functions disabled!"
    echohl None
    call s:Debug(3, "<<<<<<<< Leaving gnupg#view_recipients()")
    return
  endif

  let recipients = s:CheckRecipients(b:GPGRecipients)

  echo 'This file has following recipients (Unknown recipients have a prepended "!"):'
  " echo the recipients
  for name in recipients.valid
    let name = s:IDToName(name)
    echo name
  endfor

  " echo the unknown recipients
  echohl GPGWarning
  for name in recipients.unknown
    let name = "!" . name
    echo name
  endfor
  echohl None

  " check if there is any known recipient
  if empty(recipients.valid)
    echohl GPGError
    echom 'There are no known recipients!'
    echohl None
  endif

  call s:Debug(3, "<<<<<<<< Leaving gnupg#view_recipients()")
endfunction

" Function: gnupg#edit_recipients() {{{2
"
" create a scratch buffer with all recipients to add/remove recipients
"
function gnupg#edit_recipients()
  call s:Debug(3, ">>>>>>>> Entering gnupg#edit_recipients()")

  if s:unencrypted()
    call s:GPGDebug(3, "<<<<<<<< Leaving gnupg#edit_recipients()")
    return
  endif

  " only do this if it isn't already a GPGRecipients_* buffer
  if (!exists('b:GPGCorrespondingTo'))

    " save buffer name
    let buffername = bufname("%")
    let editbuffername = "GPGRecipients_" . buffername

    " check if this buffer exists
    if (!bufexists(editbuffername))
      " create scratch buffer
      execute 'silent! split ' . fnameescape(editbuffername)

      " add a autocommand to regenerate the recipients after a write
      autocmd BufHidden,BufUnload,BufWriteCmd <buffer> call s:FinishRecipientsBuffer()
    else
      if (bufwinnr(editbuffername) >= 0)
        " switch to scratch buffer window
        execute 'silent! ' . bufwinnr(editbuffername) . "wincmd w"
      else
        " split scratch buffer window
        execute 'silent! sbuffer ' . fnameescape(editbuffername)

        " add a autocommand to regenerate the recipients after a write
        autocmd BufHidden,BufUnload,BufWriteCmd <buffer> call s:FinishRecipientsBuffer()
      endif

      " empty the buffer
      silent %delete
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
    let recipients = s:CheckRecipients(getbufvar(b:GPGCorrespondingTo, "GPGRecipients"))

    " if there are no known or unknown recipients, use the default ones
    if (empty(recipients.valid) && empty(recipients.unknown))
      if (type(g:GPGDefaultRecipients) == type([]))
        let recipients = s:CheckRecipients(g:GPGDefaultRecipients)
      else
        echohl GPGWarning
        echom "g:GPGDefaultRecipients is not a Vim list, please correct this in your vimrc!"
        echohl None
      endif
    endif

    " put the recipients in the scratch buffer
    for name in recipients.valid
      let name = s:IDToName(name)
      silent put =name
    endfor

    " put the unknown recipients in the scratch buffer
    let syntaxPattern = ''
    if !empty(recipients.unknown)
      let flaggedNames = map(recipients.unknown, '"!".v:val')
      call append('$', flaggedNames)
      let syntaxPattern = '\(' . join(flaggedNames, '\|') . '\)'
    endif

    for line in g:GPGPossibleRecipients
        silent put ='GPG: '.line
    endfor

    " define highlight
    if (has("syntax") && exists("g:syntax_on"))
      highlight clear GPGUnknownRecipient
      if !empty(syntaxPattern)
        execute 'syntax match GPGUnknownRecipient    "' . syntaxPattern . '"'
        highlight link GPGUnknownRecipient  GPGHighlightUnknownRecipient
      endif

      syntax match GPGComment "^GPG:.*$"
      execute 'syntax match GPGComment "' . s:MagicString . '.*$"'
      highlight clear GPGComment
      highlight link GPGComment Comment
    endif

    " delete the empty first line
    silent 1delete

    " jump to the first recipient
    silent $

  endif

  call s:Debug(3, "<<<<<<<< Leaving gnupg#edit_recipients()")
endfunction

" Function: gnupg#view_options() {{{2
"
" echo the recipients
"
function gnupg#view_options()
  call s:Debug(3, ">>>>>>>> Entering gnupg#view_options()")

  if s:unencrypted()
    call s:Debug(3, "<<<<<<<< Leaving gnupg#view_options()")
    return
  endif

  if (exists("b:GPGOptions"))
    echo 'This file has following options:'
    " echo the options
    for option in b:GPGOptions
      echo option
    endfor
  endif

  call s:Debug(3, "<<<<<<<< Leaving gnupg#view_options()")
endfunction

" Function: gnupg#edit_options() {{{2
"
" create a scratch buffer with all recipients to add/remove recipients
"
function gnupg#edit_options()
  call s:Debug(3, ">>>>>>>> Entering gnupg#edit_options()")

  if s:unencrypted()
    call s:GPGDebug(3, "<<<<<<<< Leaving gnupg#edit_options()")
    return
  endif

  " only do this if it isn't already a GPGOptions_* buffer
  if (!exists('b:GPGCorrespondingTo'))

    " save buffer name
    let buffername = bufname("%")
    let editbuffername = "GPGOptions_" . buffername

    " check if this buffer exists
    if (!bufexists(editbuffername))
      " create scratch buffer
      execute 'silent! split ' . fnameescape(editbuffername)

      " add a autocommand to regenerate the options after a write
      autocmd BufHidden,BufUnload,BufWriteCmd <buffer> call s:FinishOptionsBuffer()
    else
      if (bufwinnr(editbuffername) >= 0)
        " switch to scratch buffer window
        execute 'silent! ' . bufwinnr(editbuffername) . "wincmd w"
      else
        " split scratch buffer window
        execute 'silent! sbuffer ' . fnameescape(editbuffername)

        " add a autocommand to regenerate the options after a write
        autocmd BufHidden,BufUnload,BufWriteCmd <buffer> call s:FinishOptionsBuffer()
      endif

      " empty the buffer
      silent %delete
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
    silent 1delete

    " jump to the first option
    silent $

    " define highlight
    if (has("syntax") && exists("g:syntax_on"))
      syntax match GPGComment "^GPG:.*$"
      highlight clear GPGComment
      highlight link GPGComment Comment
    endif
  endif

  call s:Debug(3, "<<<<<<<< Leaving gnupg#edit_options()")
endfunction

" Section: Script local functions {{{1

" Function: s:shellescape(s[, special]) {{{2
"
" Calls shellescape(), also taking into account 'shellslash'
" when on Windows and using $COMSPEC as the shell.
"
" Returns: shellescaped string
"
function s:shellescape(s, ...)
  let special = a:0 ? a:1 : 0
  if exists('+shellslash') && &shell == $COMSPEC
    let ssl = &shellslash
    set noshellslash

    let escaped = shellescape(a:s, special)

    let &shellslash = ssl
  else
    let escaped = shellescape(a:s, special)
  endif

  return escaped
endfunction

" Function: s:unencrypted() {{{2
"
" Determines if the buffer corresponds to an existing, unencrypted file and,
" if so, warns the user that GPG functionality has been disabled.
"
" Returns: true if current buffer corresponds to an existing, unencrypted file
function! s:unencrypted()
  if (exists("b:GPGEncrypted") && b:GPGEncrypted == 0)
    echohl GPGWarning
    echom "File is not encrypted, all GPG functions disabled!"
    echohl None
    return 1
  endif

  return 0
endfunction

" Function: s:FinishRecipientsBuffer() {{{2
"
" create a new recipient list from RecipientsBuffer
"
function s:FinishRecipientsBuffer()
  call s:Debug(3, ">>>>>>>> Entering s:FinishRecipientsBuffer()")

  if s:unencrypted()
    call s:Debug(3, "<<<<<<<< Leaving s:FinishRecipientsBuffer()")
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
    let matches = matchlist(recipient, '^\(.\{-}\)\%(' . s:MagicString . '(ID:\s\+\(' . s:keyPattern . '\)\s\+.*\)\=$')

    let recipient = matches[2] ? matches[2] : matches[1]

    " delete all spaces at beginning and end of the recipient
    " also delete a '!' at the beginning of the recipient
    let recipient = substitute(recipient, "^[[:space:]!]*\\(.\\{-}\\)[[:space:]]*$", "\\1", "")

    " delete comment lines
    let recipient = substitute(recipient, "^GPG:.*$", "", "")

    " only do this if the line is not empty
    if !empty(recipient)
      let gpgid = s:NameToID(recipient)
      if !empty(gpgid)
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
  " as modified. Buffer is now for sure an encrypted buffer.
  call setbufvar(b:GPGCorrespondingTo, "GPGRecipients", recipients)
  call setbufvar(b:GPGCorrespondingTo, "&mod", 1)
  call setbufvar(b:GPGCorrespondingTo, "GPGEncrypted", 1)

  " check if there is any known recipient
  if empty(recipients)
    echohl GPGError
    echom 'There are no known recipients!'
    echohl None
  endif

  " reset modified flag
  setl nomodified

  call s:Debug(3, "<<<<<<<< Leaving s:FinishRecipientsBuffer()")
endfunction

" Function: s:FinishOptionsBuffer() {{{2
"
" create a new option list from OptionsBuffer
"
function s:FinishOptionsBuffer()
  call s:Debug(3, ">>>>>>>> Entering s:FinishOptionsBuffer()")

  if s:unencrypted()
    call s:Debug(3, "<<<<<<<< Leaving s:FinishOptionsBuffer()")
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
    if (!empty(option) && match(options, option) < 0)
      let options += [option]
    endif
  endfor

  " write back the new option list to the corresponding buffer and mark it
  " as modified
  call setbufvar(b:GPGCorrespondingTo, "GPGOptions", options)
  call setbufvar(b:GPGCorrespondingTo, "&mod", 1)

  " reset modified flag
  setl nomodified

  call s:Debug(3, "<<<<<<<< Leaving s:FinishOptionsBuffer()")
endfunction

" Function: s:CheckRecipients(tocheck) {{{2
"
" check if recipients are known
" Returns: dictionary of recipients, {'valid': [], 'unknown': []}
"
function s:CheckRecipients(tocheck)
  call s:Debug(3, ">>>>>>>> Entering s:CheckRecipients()")

  let recipients = {'valid': [], 'unknown': []}

  if (type(a:tocheck) == type([]))
    for recipient in a:tocheck
      let gpgid = s:NameToID(recipient)
      if !empty(gpgid)
        if (match(recipients.valid, gpgid) < 0)
          call add(recipients.valid, gpgid)
        endif
      else
        if (match(recipients.unknown, recipient) < 0)
          call add(recipients.unknown, recipient)
          echohl GPGWarning
          echom "The recipient \"" . recipient . "\" is not in your public keyring!"
          echohl None
        endif
      end
    endfor
  endif

  call s:Debug(2, "recipients are: " . string(recipients.valid))
  call s:Debug(2, "unknown recipients are: " . string(recipients.unknown))

  call s:Debug(3, "<<<<<<<< Leaving s:CheckRecipients()")
  return recipients
endfunction

" Function: s:NameToID(name) {{{2
"
" find GPG key ID corresponding to a name
" Returns: ID for the given name
"
function s:NameToID(name)
  call s:Debug(3, ">>>>>>>> Entering s:NameToID()")

  " ask gpg for the id for a name
  let cmd = { 'level': 2 }
  let cmd.args = '--quiet --with-colons --fixed-list-mode --list-keys ' . s:shellescape(a:name)
  let output = s:System(cmd)

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
  let seen_keys = {}
  let skip_key = 0
  let has_strftime = exists('*strftime')
  let choices = "The name \"" . a:name . "\" is ambiguous. Please select the correct key:\n"
  for line in lines

    let fields = split(line, ":")

    " search for the next pub
    if (fields[0] == "pub")
      " check if this key has already been processed
      if has_key(seen_keys, fields[4])
        let skip_key = 1
        continue
      endif
      let skip_key = 0
      let seen_keys[fields[4]] = 1

      " Ignore keys which are not usable for encryption
      if fields[11] !~? 'e'
        continue
      endif

      let identity = fields[4]
      let gpgids += [identity]
      if has_strftime
        let choices = choices . counter . ": ID: 0x" . identity . " created at " . strftime("%c", fields[5]) . "\n"
      else
        let choices = choices . counter . ": ID: 0x" . identity . "\n"
      endif
      let counter = counter+1
      let pubseen = 1
    " search for the next uid
    elseif (!skip_key && fields[0] == "uid")
      let choices = choices . "   " . fields[9] . "\n"
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

  call s:Debug(3, "<<<<<<<< Leaving s:NameToID()")
  return get(gpgids, answer, "")
endfunction

" Function: s:IDToName(identity) {{{2
"
" find name corresponding to a GPG key ID
" Returns: Name for the given ID
"
function s:IDToName(identity)
  call s:Debug(3, ">>>>>>>> Entering s:IDToName()")

  " TODO is the encryption subkey really unique?

  " ask gpg for the id for a name
  let cmd = { 'level': 2 }
  let cmd.args = '--quiet --with-colons --fixed-list-mode --list-keys ' . a:identity
  let output = s:System(cmd)

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

    if !pubseen " search for the next pub
      if (fields[0] == "pub")
        " Ignore keys which are not usable for encryption
        if fields[11] !~? 'e'
          continue
        endif

        let pubseen = 1
      endif
    else " search for the next uid
      if (fields[0] == "uid")
        let pubseen = 0
        if exists("*strftime")
          let uid = fields[9] . s:MagicString . "(ID: 0x" . a:identity . " created at " . strftime("%c", fields[5]) . ")"
        else
          let uid = fields[9] . s:MagicString . "(ID: 0x" . a:identity . ")"
        endif
        break
      endif
    endif
  endfor

  call s:Debug(3, "<<<<<<<< Leaving s:IDToName()")
  return uid
endfunction

" Function: s:PreCmd() {{{2
"
" Setup the environment for running the gpg command
"
function s:PreCmd()
  let &shellredir = s:shellredir
  let &shell = s:shell
  let &shelltemp = s:shelltemp
  " Force C locale so GPG output is consistent
  let s:messages = v:lang
  language messages C
endfunction


" Function: s:PostCmd() {{{2
"
" Restore the user's environment after running the gpg command
"
function s:PostCmd()
  let &shellredir = s:shellredirsave
  let &shell = s:shellsave
  let &shelltemp = s:shelltempsave
  execute 'language messages' s:messages
  " Workaround a bug in the interaction between console vim and
  " pinentry-curses by forcing Vim to re-detect and setup its terminal
  " settings
  let &term = &term
  silent doautocmd TermChanged
endfunction

" Function: s:System(dict) {{{2
"
" run g:GPGCommand using system(), logging the commandline and output.  This
" uses temp files (regardless of how 'shelltemp' is set) to hold the output of
" the command, so it must not be used for sensitive commands.
" Recognized keys are:
" level - Debug level at which the commandline and output will be logged
" args - Arguments to be given to g:GPGCommand
"
" Returns: command output
"
function s:System(dict)
  let commandline = s:Command
  if (!empty(g:GPGHomedir))
    let commandline .= ' --homedir ' . s:shellescape(g:GPGHomedir)
  endif
  let commandline .= ' ' . a:dict.args
  let commandline .= ' ' . s:stderrredirnull
  call s:Debug(a:dict.level, "command: ". commandline)

  call s:PreCmd()
  let output = system(commandline)
  call s:PostCmd()

  call s:Debug(a:dict.level, "rc: ". v:shell_error)
  call s:Debug(a:dict.level, "output: ". output)
  return output
endfunction

" Function: s:Execute(dict) {{{2
"
" run g:GPGCommand using :execute, logging the commandline
" Recognized keys are:
" level - Debug level at which the commandline will be logged
" args - Arguments to be given to g:GPGCommand
" ex - Ex command which will be :executed
" redirect - Shell redirect to use, if needed
"
function s:Execute(dict)
  let commandline = printf('%s%s', a:dict.ex, s:Command)
  if (!empty(g:GPGHomedir))
    let commandline .= ' --homedir ' . s:shellescape(g:GPGHomedir, 1)
  endif
  let commandline .= ' ' . a:dict.args
  if (has_key(a:dict, 'redirect'))
    let commandline .= ' ' . a:dict.redirect
  endif
  let commandline .= ' ' . s:stderrredirnull
  call s:Debug(a:dict.level, "command: " . commandline)

  call s:PreCmd()
  execute commandline
  call s:PostCmd()

  call s:Debug(a:dict.level, "rc: ". v:shell_error)
endfunction

" Function: s:Debug(level, text) {{{2
"
" output debug message, if this message has high enough importance
" only define function if GPGDebugLevel set at all
"
function s:Debug(level, text)
  if exists("g:GPGDebugLevel") && g:GPGDebugLevel >= a:level
    if exists("g:GPGDebugLog")
      execute "redir >> " . g:GPGDebugLog
      silent echom "GnuPG: " . a:text
      redir END
    else
      echom "GnuPG: " . a:text
    endif
  endif
endfunction
