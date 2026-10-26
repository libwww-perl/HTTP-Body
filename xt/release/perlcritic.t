use strict;
use warnings;

use File::Spec;
use Test::More;

eval { require Test::Perl::Critic };
if ( $@ ) {
    plan tests => 1;
    fail( 'You must install Test::Perl::Critic to run this test' );
    exit;
}

my $rcfile = File::Spec->catfile( 'xt', 'release', 'perlcritic.rc' );
Test::Perl::Critic->import( -profile => $rcfile );
all_critic_ok();