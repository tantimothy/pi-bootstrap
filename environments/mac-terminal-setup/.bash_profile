# MacPorts: adds an appropriate PATH/MANPATH variable for use with MacPorts,
# if it's installed. Harmless no-op otherwise — run.sh doesn't try to
# install MacPorts itself (no reliable one-line installer like Homebrew's).
if [ -d /opt/local/bin ]; then
    export PATH="/opt/local/bin:/opt/local/sbin:$PATH"
    export MANPATH="/opt/local/share/man:$MANPATH"
fi

# Homebrew: set PATH, MANPATH, etc.
if [ -x /opt/homebrew/bin/brew ]; then
    eval "$(/opt/homebrew/bin/brew shellenv)"
fi

# Perl (perlbrew / local::lib), if set up on this machine
if [ -d "$HOME/perl5" ]; then
    PATH="$HOME/perl5/bin${PATH:+:${PATH}}"; export PATH;
    PERL5LIB="$HOME/perl5/lib/perl5${PERL5LIB:+:${PERL5LIB}}"; export PERL5LIB;
    PERL_LOCAL_LIB_ROOT="$HOME/perl5${PERL_LOCAL_LIB_ROOT:+:${PERL_LOCAL_LIB_ROOT}}"; export PERL_LOCAL_LIB_ROOT;
    PERL_MB_OPT="--install_base \"$HOME/perl5\""; export PERL_MB_OPT;
    PERL_MM_OPT="INSTALL_BASE=$HOME/perl5"; export PERL_MM_OPT;
fi
if [ -f "$HOME/perl5/perlbrew/etc/bashrc" ]; then
    source "$HOME/perl5/perlbrew/etc/bashrc"
fi

# User-installed Python packages (pip install --user), if present
if [ -d "$HOME/Library/Python/3.9/bin" ]; then
    PATH="$HOME/Library/Python/3.9/bin${PATH:+:${PATH}}"; export PATH;
fi

# -r file       True if file exists and is readable.
[ -r ~/.bashrc ] && source ~/.bashrc

export PATH="$HOME/.local/bin:$PATH"
