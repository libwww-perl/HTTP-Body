package HTTP::Body::MultiPart;

use strict;
use base 'HTTP::Body';
use bytes;

use IO::File;
use File::Temp 0.14;
use File::Spec;

=head1 NAME

HTTP::Body::MultiPart - HTTP Body Multipart Parser

=head1 SYNOPSIS

    use HTTP::Body::MultiPart;

=head1 DESCRIPTION

HTTP Body Multipart Parser.

=head1 METHODS

=over 4

=item init

=cut

sub init {
    my $self = shift;

    unless ( $self->content_type =~ /boundary=\"?([^\";]+)\"?/ ) {
        my $content_type = $self->content_type;
        Carp::croak("Invalid boundary in content_type: '$content_type'");
    }

    $self->{boundary} = $1;
    $self->{state}    = 'preamble';

    return $self;
}

=item spin

=cut

sub spin {
    my $self = shift;

    while (1) {

        if ( $self->{state} =~ /^(preamble|boundary|header|body)$/ ) {
            my $method = "parse_$1";
            return unless $self->$method;
        }

        else {
            Carp::croak('Unknown state');
        }
    }
}

=item boundary

=cut

sub boundary {
    return shift->{boundary};
}

=item boundary_begin

=cut

sub boundary_begin {
    return "--" . shift->boundary;
}

=item boundary_end

=cut

sub boundary_end {
    return shift->boundary_begin . "--";
}

=item crlf

=cut

sub crlf () {
    return "\x0d\x0a";
}

=item delimiter_begin

=cut

sub delimiter_begin {
    my $self = shift;
    return $self->crlf . $self->boundary_begin;
}

=item delimiter_end

=cut

sub delimiter_end {
    my $self = shift;
    return $self->crlf . $self->boundary_end;
}

=item parse_preamble

=cut

sub parse_preamble {
    my $self = shift;

    my $index = index( $self->{buffer}, $self->boundary_begin );

    unless ( $index >= 0 ) {
        # keep only what may be the start of a dash-boundary split across chunks
        my $keep = length( $self->boundary_begin ) - 1;
        substr( $self->{buffer}, 0, -$keep, '' ) if length( $self->{buffer} ) > $keep;
        return 0;
    }

    # replace preamble with CRLF so we can match dash-boundary as delimiter
    substr( $self->{buffer}, 0, $index, $self->crlf );

    $self->{state} = 'boundary';

    return 1;
}

=item parse_boundary

=cut

our $max_parts = 1000;

sub parse_boundary {
    my $self = shift;

    if ( index( $self->{buffer}, $self->delimiter_begin . $self->crlf ) == 0 ) {

        if ( $max_parts && ++$self->{part_count} > $max_parts ) {
            Carp::croak("Too many parts in multipart body (limit $max_parts)");
        }

        substr( $self->{buffer}, 0, length( $self->delimiter_begin ) + 2, '' );
        $self->{part}  = {};
        $self->{state} = 'header';

        return 1;
    }

    if ( index( $self->{buffer}, $self->delimiter_end . $self->crlf ) == 0 ) {

        substr( $self->{buffer}, 0, length( $self->delimiter_end ) + 2, '' );
        $self->{part}  = {};
        $self->{state} = 'done';

        return 0;
    }

    if ( length( $self->{buffer} ) >= length( $self->delimiter_end ) + 2 ) {
        # a close delimiter ends the body whatever follows it (padding, epilogue)
        unless ( index( $self->{buffer}, $self->delimiter_end ) == 0 ) {
            Carp::croak('Invalid multipart boundary delimiter');
        }
        substr( $self->{buffer}, 0, length( $self->delimiter_end ), '' );
        $self->{part}  = {};
        $self->{state} = 'done';
    }

    return 0;
}

=item parse_header

=cut

our $max_header_size  = 32 * 1024;
our $max_header_lines = 100;

sub parse_header {
    my $self = shift;

    my $crlf  = $self->crlf;
    my $index = index( $self->{buffer}, $crlf . $crlf );

    # Without the blank line yet, the last 3 bytes may be its start.
    my $size = $index >= 0 ? $index : length( $self->{buffer} ) - 3;
    if ( $max_header_size && $size > $max_header_size ) {
        Carp::croak("Multipart part header exceeds $max_header_size bytes");
    }

    unless ( $index >= 0 ) {
        return 0;
    }

    my $header = substr( $self->{buffer}, 0, $index );

    if ( $max_header_lines && ( $header =~ tr/\n// ) >= $max_header_lines ) {
        Carp::croak("Multipart part header exceeds $max_header_lines lines");
    }

    substr( $self->{buffer}, 0, $index + 4, '' );

    my @headers;
    for ( split /$crlf/, $header ) {
        if (s/^[ \t]+//) {
            # a continuation line; with no line to continue it is dropped
            $headers[-1] .= $_ if @headers;
        }
        else {
            push @headers, $_;
        }
    }

    my $token = qr/[^][\x00-\x1f\x7f()<>@,;:\\"\/?={} \t]+/;

    for my $header (@headers) {

        # A line that is no header field is dropped: without a match $1 would
        # still hold whatever the last successful match captured.
        next unless $header =~ s/^($token):[\t ]*//;

        ( my $field = $1 ) =~ s/\b(\w)/uc($1)/eg;

        if ( exists $self->{part}->{headers}->{$field} ) {
            for ( $self->{part}->{headers}->{$field} ) {
                $_ = [$_] unless ref($_) eq "ARRAY";
                push( @$_, $header );
            }
        }
        else {
            $self->{part}->{headers}->{$field} = $header;
        }
    }

    $self->{state} = 'body';

    return 1;
}

=item parse_body

=cut

sub parse_body {
    my $self = shift;

    my $index = index( $self->{buffer}, $self->delimiter_begin );

    if ( $index < 0 ) {

        # make sure we have enough buffer to detect end delimiter
        my $length = length( $self->{buffer} ) - ( length( $self->delimiter_end ) + 2 );

        unless ( $length > 0 ) {
            return 0;
        }

        $self->{part}->{data} .= substr( $self->{buffer}, 0, $length, '' );
        $self->{part}->{size} += $length;
        $self->{part}->{done} = 0;

        $self->handler( $self->{part} );

        return 0;
    }

    $self->{part}->{data} .= substr( $self->{buffer}, 0, $index, '' );
    $self->{part}->{size} += $index;
    $self->{part}->{done} = 1;

    $self->handler( $self->{part} );

    $self->{state} = 'boundary';

    return 1;
}

=item handler

=cut

# The default is also kept here: while $basename_regexp still holds it, the
# suffix is found by _default_suffix, a string search with the same result.
my $default_basename_regexp = qr/[^.]+(\.[^\\\/]+)$/;

our $basename_regexp = $default_basename_regexp;
our $file_temp_suffix = '.upload';
our $file_temp_template;
our %file_temp_parameters;

sub handler {
    my ( $self, $part ) = @_;

    unless ( exists $part->{name} ) {

        my $disposition = $part->{headers}->{'Content-Disposition'};
        my ($name)      = $disposition =~ / name="?([^\";]+)"?/;
        my ($filename)  = $disposition =~ / filename="?([^\"]*)"?/;
        # Need to match empty filenames above, so this part is flagged as an upload type

        $part->{name}     = $name;
        $part->{filename} = $filename if defined $filename;
    }

    # A file part gets its temporary file on the first call, also when a
    # subclass has named the part and set its filename itself.
    if ( defined $part->{filename} && !exists $part->{tempname} ) {

        # A NUL in the filename truncates the path for anything downstream that
        # hands it to the C layer, so strip it before the name is used or stored.
        $part->{filename} =~ s/\0//g;

        if ( $part->{filename} ne "" ) {
            my $suffix = $file_temp_suffix;

            unless ($suffix) {
                my $basename = (File::Spec->splitpath($part->{filename}))[2];

                # A suffix can be no longer than a file name, so only the end
                # of a long basename is looked at.  On the whole of a hostile
                # one a regexp like the default backtracks in time quadratic
                # in its length: seconds per part, once for every part.
                $basename = substr( $basename, -255 ) if length($basename) > 255;

                if ( ref $basename_regexp && $basename_regexp == $default_basename_regexp ) {
                    $suffix = _default_suffix($basename);
                }
                else {
                    $suffix = $basename =~ $basename_regexp ? $1 : q{};
                }
            }

            my $fh = File::Temp->new(
                UNLINK => 0, DIR => $self->tmpdir, SUFFIX => $suffix,
                ( $file_temp_template ? ( TEMPLATE => $file_temp_template ) : () ),
                %file_temp_parameters,
            );

            $part->{fh}       = $fh;
            $part->{tempname} = $fh->filename;
        }
    }

    if ( $part->{fh} && ( my $length = length( $part->{data} ) ) ) {
        $part->{fh}->write( substr( $part->{data}, 0, $length, '' ), $length )
            or Carp::croak("Can't write to temporary file: $!");
    }

    if ( $part->{done} ) {

        if ( exists $part->{filename} ) {
            if ( $part->{filename} ne "" ) {
                # A buffered write error often surfaces only here, at close.
                if ( defined $part->{fh} ) {
                    $part->{fh}->close
                        or Carp::croak("Can't close temporary file: $!");
                }

                delete @{$part}{qw[ data done fh ]};

                $self->upload( $part->{name}, $part );
            }
        }
        # If we have more than the content-disposition, we need to create a
        # data key so that we don't waste the headers.
        else {
            $self->param( $part->{name}, $part->{data} );
            $self->part_data( $part->{name}, $part )
        }
    }
}

# The suffix the default $basename_regexp captures, found without a regexp,
# in time linear in the basename's length.  It starts at the first dot after
# the last slash or backslash that follows a byte other than a dot, and runs
# to the end; a dot that is the last byte gives no suffix.
sub _default_suffix {
    my ($basename) = @_;

    my $last = length($basename) - 1;
    my $dot  = rindex( $basename, '/' );
    my $back = rindex( $basename, '\\' );
    $dot = $back if $back > $dot;

    while ( ( $dot = index( $basename, '.', $dot + 1 ) ) >= 0 ) {
        return q{} if $dot == $last;
        return substr( $basename, $dot )
            if $dot > 0 && substr( $basename, $dot - 1, 1 ) ne '.';
    }

    return q{};
}

=back

=head1 SUPPORT

See L<HTTP::Body>

=head1 AUTHOR

Christian Hansen, C<ch@ngmedia.com>

=head1 LICENSE

This library is free software . You can redistribute it and/or modify 
it under the same terms as perl itself.

=cut

1;
