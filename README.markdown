# vim-gnupg

This script implements transparent editing of gpg encrypted files. The filename
must have a `.gpg`, `.pgp` or `.asc` suffix. When opening such a file the
content is decrypted, when opening a new file the script will ask for the
recipients of the encrypted file. The file content will be encrypted to all
recipients before it is written. The script turns off viminfo, swapfile, and
undofile to increase security.

## Installation

Copy the `gnupg.vim` file to the `$HOME/.vim/plugin` directory. Refer to `:help
add-plugin`, `:help add-global-plugin` and `:help runtimepath` for more details
about Vim plugins.

From `man 1 gpg-agent`:

> You should always add the following lines to your `.bashrc` or whatever
> initialization file is used for all shell invocations:
>
>     GPG_TTY=`tty`
>     export GPG_TTY
>
> It is important that this environment variable always reflects the output of
> the tty command. For W32 systems this option is not required.

Most distributions provide software to ease handling of gpg and gpg-agent.
Examples are keychain or seahorse.

If there are specific actions that should take place when editing a
GnuPG-managed buffer, an autocmd for the User event and GnuPG pattern can be
defined. For example, the following will set `textwidth` to 72 for all
GnuPG-encrypted buffers:

    autocmd User GnuPG setl textwidth=72

This will be triggered before any BufRead or BufNewFile autocmds, and therefore
will not take precedence over settings specific to any filetype that may get
set.

## Known Issues

In some cases gvim can't decrypt files.

This is caused by the fact that a running gvim has no TTY and thus gpg is not
able to ask for the passphrase by itself. This is a problem for Windows and
Linux versions of gvim and could not be solved unless a "terminal emulation" is
implemented for gvim. To circumvent this you have to use any combination of
gpg-agent and a graphical pinentry program:

- gpg-agent only:
  you need to provide the passphrase for the needed key to gpg-agent
  in a terminal before you open files with gvim which require this key.
- pinentry only:
  you will get a popup window every time you open a file that needs to
  be decrypted.
- gpgagent and pinentry:
  you will get a popup window the first time you open a file that
  needs to be decrypted.

## Credits

- Mathieu Clabaut for inspirations through his vimspell.vim script.
- Richard Bronosky for patch to enable `.pgp` suffix.
- Erik Remmelzwaal for patch to enable windows support and patient beta testing.
- Lars Becker for patch to make gpg2 working.
- Thomas Arendsen Hein for patch to convert encoding of gpg output.
- Karl-Heinz Ruskowski for patch to fix unknown recipients and trust model and
  patient beta testing.
- Giel van Schijndel for patch to get `GPG_TTY` dynamically.
- Sebastian Luettich for patch to fix issue with symmetric encryption an set
  recipients.
- Tim Swast for patch to generate signed files.
- James Vega for patches for better `*.asc` handling, better filename escaping
  and better handling of multiple keyrings.

## License

This program is free software; you can redistribute it and/or modify it under
the terms of the GNU General Public License as published by the Free Software
Foundation; either version 2 of the License, or (at your option) any later
version. See http://www.gnu.org/copyleft/gpl-2.0.txt
