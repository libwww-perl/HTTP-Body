package HTTP::Body;

use strict;

use Carp       qw[ ];

our $TYPES = {
    'application/octet-stream'          => 'HTTP::Body::OctetStream',
    'application/x-www-form-urlencoded' => 'HTTP::Body::UrlEncoded',
    'multipart/form-data'               => 'HTTP::Body::MultiPart',
    'multipart/related'                 => 'HTTP::Body::XFormsMultipart',
    'application/xml'                   => 'HTTP::Body::XForms',
    'application/json'                  => 'HTTP::Body::OctetStream',
};

require HTTP::Body::OctetStream;
require HTTP::Body::UrlEncoded;
require HTTP::Body::MultiPart;
require HTTP::Body::XFormsMultipart;
require HTTP::Body::XForms;

use HTTP::Headers;
use HTTP::Message;

=head1 NAME

HTTP::Body - HTTP Body Parser

=head1 SYNOPSIS

    use HTTP::Body;
    
    sub handler : method {
        my ( $class, $r ) = @_;

        my $content_type   = $r->headers_in->get('Content-Type');
        my $content_length = $r->headers_in->get('Content-Length');
        
        my $body   = HTTP::Body->new( $content_type, $content_length );
        my $length = $content_length;

        while ( $length ) {

            $r->read( my $buffer, ( $length < 8192 ) ? $length : 8192 );

            $length -= length($buffer);
            
            $body->add($buffer);
        }
        
        my $uploads     = $body->upload;     # hashref
        my $params      = $body->param;      # hashref
        my $param_order = $body->param_order # arrayref
        my $body        = $body->body;       # IO::Handle
    }

=head1 DESCRIPTION

HTTP::Body parses chunks of HTTP POST data and supports
application/octet-stream, application/json, application/x-www-form-urlencoded,
and multipart/form-data.

Chunked bodies are supported by not passing a length value to new().

It is currently used by L<Catalyst>, L<Dancer>, L<Maypole>, L<Web::Simple> and
L<Jedi>.

=head1 NOTES

When parsing multipart bodies, temporary files are created to store any
uploaded files.  You must delete these temporary files yourself after
processing them, or set $body->cleanup(1) to automatically delete them at
DESTROY-time.  The temporary file of a file part that is still incomplete
at DESTROY-time is never returned by upload, so it is always deleted.

=head2 Limits

To stop hostile input from exhausting memory or CPU, add() enforces a few
limits and croaks when one is exceeded.  Each is a package variable you can
raise to suit your forms, or set to 0 (or undef) to disable.

=over 4

=item $HTTP::Body::MultiPart::max_parts

=item $HTTP::Body::UrlEncoded::max_params

The largest number of parts in a multipart body, and of fields in a urlencoded
body (counted as C<&> and C<;> separators, empty fields included); more make
add croak.  The default for both is 1000.

=item $HTTP::Body::MultiPart::max_header_size

=item $HTTP::Body::MultiPart::max_header_lines

The largest header block a multipart part may have, in bytes and in lines; a
larger one makes add croak.  The defaults are 32768 and 100.

=item $HTTP::Body::max_chunk_line_size

The largest chunk-size line (size, extensions and CRLF) of a chunked body, in
bytes; a longer one makes add croak.  The default is 1024.  A chunked body
whose framing is malformed (a line that is no chunk-size line, a size that does
not fit an integer, chunk data not followed by CRLF) makes add croak as well.

=back

=head1 METHODS

=over 4 

=item new 

Constructor. Takes content type and content length as parameters,
returns a L<HTTP::Body> object.

=cut

sub new {
    my ( $class, $content_type, $content_length ) = @_;

    unless ( @_ >= 2 ) {
        Carp::croak( $class, '->new( $content_type, [ $content_length ] )' );
    }

    my $type;
    my $earliest_index;
    foreach my $supported ( keys %{$TYPES} ) {
        my $index = index( lc($content_type), $supported );
        if ($index >= 0 && (!defined $earliest_index || $index < $earliest_index)) {
            $type           = $supported;
            $earliest_index = $index;
        }
    }

    my $body = $TYPES->{ $type || 'application/octet-stream' };

    my $self = {
        cleanup        => 0,
        buffer         => '',
        chunk_buffer   => '',
        chunk_remaining => 0,
        chunk_crlf     => 0,
        chunk_eof      => 0,
        body           => undef,
        chunked        => !defined $content_length,
        content_length => defined $content_length ? $content_length : -1,
        content_type   => $content_type,
        length         => 0,
        param          => {},
        param_order    => [],
        state          => 'buffering',
        upload         => {},
        part_data      => {},
        owner          => _owner(),
        tmpdir         => File::Spec->tmpdir(),
    };

    bless( $self, $body );

    return $self->init;
}

# A forked child or a new thread gets a copy of the object, not of the upload.
sub _owner {
    return $$ . ' ' . ( $INC{'threads.pm'} ? threads->tid : 0 );
}

sub DESTROY {
    my $self = shift;

    # An unfinished file part is not in upload(); at global destruction its fh may be gone.
    if ( $self->{owner} eq _owner() && $self->{part} && exists $self->{part}->{fh} ) {
        my $fh = delete $self->{part}->{fh};
        close $fh if $fh;
        unlink $self->{part}->{tempname};
    }

    if ( $self->{cleanup} ) {
        my @temps = ();
        for my $upload ( values %{ $self->{upload} } ) {
            push @temps, map { $_->{tempname} || () }
                ( ref $upload eq 'ARRAY' ? @{$upload} : $upload );
        }
        
        unlink map { $_ } grep { -e $_ } @temps;
    }
}

=item add

Add string to internal buffer. Will call spin unless done. returns
length before adding self.

=cut

# chunk-size [ chunk-ext ] CRLF, matched against one line at a time.  The
# atomic group keeps the size digits from backtracking into the rest of the
# line, and the line length limit bounds what the rest can cost.
my $chunk_size_line = qr/^(?>([\da-fA-F]+))[^\n]*\x0D\x0A\z/;

our $max_chunk_line_size = 1024;

sub add {
    my $self = shift;

    if ( $self->{chunked} ) {

        # Nothing after the zero-length chunk belongs to the body: trailing
        # bytes must neither be reparsed as chunks nor pile up in the buffer.
        return if $self->{chunk_eof};

        $self->{chunk_buffer} .= $_[0] if defined $_[0];

        while ( !$self->{chunk_eof} ) {

            # Inside a chunk: pass its data on as it arrives, so that a chunk
            # never needs as much memory as it is long.
            if ( $self->{chunk_remaining} ) {
                my $take = length $self->{chunk_buffer};
                $take = $self->{chunk_remaining} if $take > $self->{chunk_remaining};

                # wait for more calls to add()
                return unless $take;

                my $data = substr( $self->{chunk_buffer}, 0, $take, '' );
                $self->{chunk_remaining} -= $take;
                $self->{length}          += $take;

                # Once the body parser is done (multipart is, at its close
                # delimiter) the rest of the body is consumed but not kept.
                unless ( $self->{state} eq 'done' ) {
                    $self->{buffer} .= $data;
                    $self->spin;
                }

                next;
            }

            # The CRLF that ends the data of the chunk just read.
            if ( $self->{chunk_crlf} ) {
                return if length( $self->{chunk_buffer} ) < 2;

                unless ( substr( $self->{chunk_buffer}, 0, 2, '' ) eq "\x0D\x0A" ) {
                    Carp::croak('Chunk data not followed by CRLF');
                }

                $self->{chunk_crlf} = 0;
            }

            # A chunk-size line.  Its length is checked before it is complete,
            # so that an endless line can not grow the buffer.
            my $eol      = index( $self->{chunk_buffer}, "\x0A" );
            my $line_len = $eol >= 0 ? $eol + 1 : length $self->{chunk_buffer};

            if ( $max_chunk_line_size && $line_len > $max_chunk_line_size ) {
                Carp::croak("Chunk size line exceeds $max_chunk_line_size bytes");
            }

            # wait for the rest of the line
            return if $eol < 0;

            my $line = substr( $self->{chunk_buffer}, 0, $line_len, '' );

            unless ( $line =~ $chunk_size_line ) {
                Carp::croak('Invalid chunk size line');
            }

            # hex() of a size that does not fit an integer warns and returns a
            # float, which no buffer length would ever reach.
            ( my $digits = $1 ) =~ s/^0+//;
            if ( length($digits) > 15 ) {
                Carp::croak('Chunk size too large');
            }

            my $chunk_len = hex($digits);

            if ( $chunk_len == 0 ) {
                # End of data, there may be trailing headers
                if (  my ($headers) = $self->{chunk_buffer} =~ m/(.*)\x0D\x0A/s ) {
                    if ( my $message = HTTP::Message->parse( $headers ) ) {
                        $self->{trailing_headers} = $message->headers;
                    }
                }

                $self->{chunk_buffer} = '';
                $self->{chunk_eof}    = 1;

                # Set content_length equal to the amount of data we read,
                # so the spin methods can finish up.
                $self->{content_length} = $self->{length};

                unless ( $self->{state} eq 'done' ) {
                    $self->spin;
                }

                return;
            }

            $self->{chunk_remaining} = $chunk_len;
            $self->{chunk_crlf}      = 1;
        }

        return;
    }
    
    my $cl = $self->content_length;

    if ( defined $_[0] ) {
        $self->{length} += length( $_[0] );
        
        # Don't allow buffer data to exceed content-length
        if ( $self->{length} > $cl ) {
            $_[0] = substr $_[0], 0, $cl - $self->{length};
            $self->{length} = $cl;
        }
        
        $self->{buffer} .= $_[0];
    }

    unless ( $self->state eq 'done' ) {
        $self->spin;
    }

    return ( $self->length - $cl );
}

=item body

accessor for the body.

=cut

sub body {
    my $self = shift;
    $self->{body} = shift if @_;
    return $self->{body};
}

=item chunked

Returns 1 if the request is chunked.

=cut

sub chunked {
    return shift->{chunked};
}

=item cleanup

Set to 1 to enable automatic deletion of temporary files at DESTROY-time.

=cut

sub cleanup {
    my $self = shift;
    $self->{cleanup} = shift if @_;
    return $self->{cleanup};
}

=item content_length

Returns the content-length for the body data if known.
Returns -1 if the request is chunked.

=cut

sub content_length {
    return shift->{content_length};
}

=item content_type

Returns the content-type of the body data.

=cut

sub content_type {
    return shift->{content_type};
}

=item init

return self.

=cut

sub init {
    return $_[0];
}

=item length

Returns the total length of data we expect to read if known.
In the case of a chunked request, returns the amount of data
read so far.

=cut

sub length {
    return shift->{length};
}

=item trailing_headers

If a chunked request body had trailing headers, trailing_headers will
return an HTTP::Headers object populated with those headers.

=cut

sub trailing_headers {
    return shift->{trailing_headers};
}

=item spin

Abstract method to spin the io handle.

=cut

sub spin {
    Carp::croak('Define abstract method spin() in implementation');
}

=item state

Returns the current state of the parser.

=cut

sub state {
    my $self = shift;
    $self->{state} = shift if @_;
    return $self->{state};
}

=item param

Get/set body parameters.

=cut

sub param {
    my $self = shift;

    if ( @_ == 2 ) {

        my ( $name, $value ) = @_;

        if ( exists $self->{param}->{$name} ) {
            for ( $self->{param}->{$name} ) {
                $_ = [$_] unless ref($_) eq "ARRAY";
                push( @$_, $value );
            }
        }
        else {
            $self->{param}->{$name} = $value;
        }

        push @{$self->{param_order}}, $name;
    }

    return $self->{param};
}

=item upload

Get/set file uploads.

=cut

sub upload {
    my $self = shift;

    if ( @_ == 2 ) {

        my ( $name, $upload ) = @_;

        if ( exists $self->{upload}->{$name} ) {
            for ( $self->{upload}->{$name} ) {
                $_ = [$_] unless ref($_) eq "ARRAY";
                push( @$_, $upload );
            }
        }
        else {
            $self->{upload}->{$name} = $upload;
        }
    }

    return $self->{upload};
}

=item part_data

Just like 'param' but gives you a hash of the full data associated with the
part in a multipart type POST/PUT.  Example:

    {
      data => "test",
      done => 1,
      headers => {
        "Content-Disposition" => "form-data; name=\"arg2\"",
        "Content-Type" => "text/plain"
      },
      name => "arg2",
      size => 4
    }

=cut

sub part_data {
    my $self = shift;

    if ( @_ == 2 ) {

        my ( $name, $data ) = @_;

        if ( exists $self->{part_data}->{$name} ) {
            for ( $self->{part_data}->{$name} ) {
                $_ = [$_] unless ref($_) eq "ARRAY";
                push( @$_, $data );
            }
        }
        else {
            $self->{part_data}->{$name} = $data;
        }
    }

    return $self->{part_data};
}

=item tmpdir 

Specify a different path for temporary files.  Defaults to the system temporary path.

=cut

sub tmpdir {
    my $self = shift;
    $self->{tmpdir} = shift if @_;
    return $self->{tmpdir};
}

=item param_order

Returns the array ref of the param keys in the order how they appeared on the body

=cut

sub param_order {
    return shift->{param_order};
}

=back

=head1 CONFIGURING UPLOAD TEMPORARY FILES

By default, the temporary file that holds an uploaded file is given the
extension C<.upload> instead of the extension of the uploaded file itself.
The following package variables control how these temporary files are created.

=over 4

=item $HTTP::Body::MultiPart::file_temp_suffix

The extension given to every multipart upload file; the default is C<.upload>.
Set it to undef to keep the extension of the uploaded file instead, as releases
before 1.23 did.

=item $HTTP::Body::MultiPart::basename_regexp

The regexp used to work out the uploaded file's extension.  It only matters
when C<file_temp_suffix> is undefined, and is matched against the last 255
bytes of the uploaded file's basename, which is as long as a suffix can be.

=item $HTTP::Body::MultiPart::file_temp_template

Passed through to the L<File::Temp> TEMPLATE parameter.  There is no special
default in our module.

=item %HTTP::Body::MultiPart::file_temp_parameters

Extra settings for the L<File::Temp> invocation.  These override every other
setting.

=back

=head1 SUPPORT

=over 4

=item * GitHub Issues

L<https://github.com/libwww-perl/HTTP-Body/issues>

=item * MetaCPAN

L<https://metacpan.org/release/HTTP-Body>

=item * Source Code

L<https://github.com/libwww-perl/HTTP-Body>

=item * IRC

C<#catalyst> on C<irc.perl.org> for users, C<#catalyst-dev> for contributors

=back

Note: This project was formerly hosted on the Shadowcat Systems git server.
The repository has moved to L<GitHub|https://github.com/libwww-perl/HTTP-Body>.

=head1 AUTHOR

Christian Hansen, C<christian.hansen@mac.com>

Sebastian Riedel, C<kraihx@googlemail.com>

Andy Grundman, C<andy@hybridized.org>

=head1 MAINTAINER

Torsten Raudssus, C<torsten@raudssus.de>

=head1 CONTRIBUTORS

Simon Elliott C<cpan@papercreatures.com>

Kent Fredric C<kentnl@cpan.org>

Christian Walde C<walde.christian@gmail.com>

=head1 LICENSE

This library is free software. You can redistribute it and/or modify 
it under the same terms as perl itself.

=cut

1;
