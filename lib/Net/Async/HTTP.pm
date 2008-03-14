#  You may distribute under the terms of either the GNU General Public License
#  or the Artistic License (the same terms as Perl itself)
#
#  (C) Paul Evans, 2008 -- leonerd@leonerd.org.uk

package Net::Async::HTTP;

use strict;

our $VERSION = '0.01';

use Carp;

use HTTP::Request;
use HTTP::Response;
use HTTP::Request::Common qw();

use Socket qw( SOCK_STREAM );

my $CRLF = "\x0d\x0a"; # More portable than \r\n

=head1 NAME

C<Net::Async::HTTP> - Asynchronous HTTP client

=head1 SYNOPSIS

 use IO::Async::Loop::...;
 use Net::Async::HTTP;
 use URI;

 my $loop = IO::Async::Loop::...;

 my $client = Net::Async::HTTP->new( loop => $loop );

 $client->do_request(
    uri => URI->new( "http://www.cpan.org/" ),

    on_response => sub {
       my ( $response ) = @_;
       print "Front page of http://www.cpan.org/ is:\n";
       print $response->as_string;
       $loop->loop_stop;
    },

    on_error => sub {
       my ( $message ) = @_;
       print "Cannot fetch http://www.cpan.org/ - $message\n";
       $loop->loop_stop;
    },
 );

 $loop->loop_forever;

=head1 DESCRIPTION

This object class implements an asynchronous HTTP client. It sends requests to
servers, and invokes continuation callbacks when responses are received. The
object supports multiple concurrent connections to servers, and allows
multiple outstanding requests in pipeline to any one connection. Normally,
only one such object will be needed per program to support any number of
requests.

=cut

=head1 CONSTRUCTOR

=cut

=head2 $client = Net::Async::HTTP->new( %args )

This function returns a new instance of a C<Net::Async::HTTP> object. It takes
the following named arguments:

=over 8

=item loop => IO::Async::Loop

A reference to an C<IO::Async::Loop> object.

=back

=cut

sub new
{
   my $class = shift;
   my %args = @_;

   my $loop = delete $args{loop} or croak "Need a 'loop'";

   my $self = bless {
      loop => $loop,

      connections => {}, # { "$host:$port" } -> [ $conn, @pending_onread ]
   }, $class;

   return $self;
}

=head1 METHODS

=cut

sub get_connection
{
   my $self = shift;
   my %args = @_;

   my $on_ready = $args{on_ready} or croak "Expected 'on_ready' as a CODE ref";
   my $on_error = $args{on_error} or croak "Expected 'on_error' as a CODE ref";

   my $loop = $self->{loop};

   my $host = $args{host};
   my $port = $args{port};

   if( my $cr = $self->{connections}->{"$host:$port"} ) {
      my ( $conn ) = @$cr;

      my $on_read = $on_ready->( $conn );
      push @$cr, $on_read;

      return;
   }

   if( $args{handle} ) {
      my $on_read;

      my $cr;

      my $conn = IO::Async::Stream->new(
         handle => $args{handle},

         on_read => sub {
            my ( $conn, $buffref, $closed ) = @_;

            if( defined $on_read ) {
               my $r = $on_read->( $conn, $buffref, $closed );
               if( ref $r eq "CODE" ) {
                  $on_read = $r;
                  return 1;
               }
               elsif( defined $r ) {
                  return $r;
               }
               else {
                  if( @$cr > 1 ) {
                     $on_read = splice @$cr, 1, 1;
                     return 1;
                  }

                  $conn->close;
                  delete $self->{connections}->{"$host:$port"};
                  return 0;
               }
            }
            else {
               die "Spurious on_read of connection while idle\n";
            }
         },
      );

      $cr = $self->{connections}->{"$host:$port"} = [ $conn ];

      $loop->add( $conn );

      $on_read = $on_ready->( $conn );

      return;
   }

   $loop->connect(
      host     => $host,
      service  => $port,
      socktype => SOCK_STREAM,

      on_resolve_error => sub {
         $on_error->( "$host:$port not resolvable [$_[0]]" );
      },

      on_connect_error => sub {
         $on_error->( "$host:$port not contactable" );
      },

      on_connected => sub {
         my ( $sock ) = @_;
         $self->get_connection( %args, handle => $sock );
      },
   );
}

=head2 $client->do_request( %args )

Send an HTTP request to a server, and receive a reply. The request may be
represented by an C<HTTP::Request> object, or a C<URI> object.

The following named arguments are used for C<HTTP::Request>s:

=over 8

=item request => HTTP::Request

A reference to an C<HTTP::Request> object

=item host => STRING

=item port => INT

Hostname and port number of the server to connect to

=back

The following named arguments are used for C<URI> requests:

=over 8

=item uri => URI

A reference to a C<URI> object

=item method => STRING

Optional. The HTTP method. If missing, C<GET> is used.

=item content => STRING

Optional. The body content to use for C<POST> requests.

=item user => STRING

=item pass => STRING

Optional. If both are given, the HTTP Basic Authorization header will be sent
with these details.

=item proxy_host => STRING

=item proxy_port => INT

Optional. Override the hostname or port number implied by the URI.

=back

It takes the following continuation callbacks:

=over 8

=item on_response => CODE

A callback that is invoked when a response to this request has been received.
It will be passed an C<HTTP::Response> object containing the response the
server sent.

 $on_response->( $response )

=item on_error => CODE

A callback that is invoked if an error occurs while trying to send the request
or obtain the response. It will be passed an error message.

 $on_error->( $message )

=back

=cut

sub do_request
{
   my $self = shift;
   my %args = @_;

   my $on_response = $args{on_response} or croak "Expected 'on_response' as a CODE ref";
   my $on_error    = $args{on_error}    or croak "Expected 'on_error' as a CODE ref";

   my $request;

   my $host;
   my $port;

   if( $args{request} ) {
      $request = delete $args{request};
      ref $request and $request->isa( "HTTP::Request" ) or croak "Expected 'request' as a HTTP::Request reference";
   }
   elsif( $args{uri} ) {
      my $uri = delete $args{uri};
      ref $uri and $uri->isa( "URI" ) or croak "Expected 'uri' as a URI reference";

      my $method = delete $args{method} || "GET";

      $host = $uri->host;
      $port = $uri->port;
      my $path = $uri->path_query;

      $path = "/" if $path eq "";

      if( $method eq "POST" ) {
         # This will automatically encode a form for us
         $request = HTTP::Request::Common::POST( $path, Content => $args{content} );
      }
      else {
         $request = HTTP::Request->new( $method, $path );
      }

      $request->protocol( "HTTP/1.1" );
      $request->header( Host => $host );

      my ( $user, $pass );

      if( defined $uri->userinfo ) {
         ( $user, $pass ) = split( m/:/, $uri->userinfo, 2 );
      }
      elsif( defined $args{user} and defined $args{pass} ) {
         $user = $args{user};
         $pass = $args{pass};
      }

      if( defined $user and defined $pass ) {
         $request->authorization_basic( $user, $pass );
      }
   }

   if( $args{handle} ) { # INTERNAL UNDOCUMENTED
      $self->get_connection(
         handle => $args{handle},

         # To make the connection cache logic happy
         host => "[[local_io_handle]]",
         port => fileno $args{handle},

         on_error => $on_error,

         on_ready => sub {
            my ( $conn ) = @_;
            return $self->do_request_conn(
               %args,
               request => $request,
               conn    => $conn,
            );
         },
      );
   }
   else {
      if( !defined $host ) {
         $host = delete $args{host} or croak "Expected 'host'";
      }

      if( !defined $port ) {
         $port = delete $args{port} or croak "Expected 'port'";
      }

      $self->get_connection(
         host => $args{proxy_host} || $host,
         port => $args{proxy_port} || $port,

         on_error => $on_error,

         on_ready => sub {
            my ( $conn ) = @_;
            return $self->do_request_conn(
               %args,
               request => $request,
               conn    => $conn,
            );
         },
      );
   }
}

sub do_request_conn
{
   my $self = shift;
   my %args = @_;

   my $on_response = $args{on_response} or croak "Expected 'on_response' as a CODE ref";
   my $on_error    = $args{on_error}    or croak "Expected 'on_error' as a CODE ref";
   
   my $req = $args{request};
   ref $req and $req->isa( "HTTP::Request" ) or croak "Expected 'request' as a HTTP::Request reference";

   my $method = $req->method;

   my $conn = $args{conn};

   if( $method eq "POST" or $method eq "PUT" or length $req->content ) {
      $req->init_header( "Content-Length", length $req->content );
   }

   # HTTP::Request is silly and uses "\n" as a separator. We must tell it to
   # use the correct RFC 2616-compliant CRLF sequence.
   $conn->write( $req->as_string( $CRLF ) );

   # Now construct the on_read closure
   return sub {
      my ( $conn, $buffref, $closed ) = @_;

      unless( $$buffref =~ s/^(.*?$CRLF$CRLF)//s ) {
         $on_error->( "Connection closed while awaiting header" ) if $closed;
         return 0;
      }

      my $response_header = $1;
      my $response = HTTP::Response->parse( $response_header );

      my $code = $response->code;

      # RFC 2616 says "HEAD" does not have a body, nor do any 1xx codes, nor
      # 204 (No Content) nor 304 (Not Modified)
      if( $method eq "HEAD" or $code =~ m/^1..$/ or $code eq "204" or $code eq "304" ) {
         $on_response->( $response );
         return undef; # Finished
      }

      my $transfer_encoding = $response->header( "Transfer-Encoding" );
      my $content_length = $response->content_length;

      if( defined $transfer_encoding and $transfer_encoding eq "chunked" ) {
         my $chunk_length;

         return sub {
            my ( $conn, $buffref, $closed ) = @_;

            if( !defined $chunk_length and $$buffref =~ s/^(.*?)$CRLF// ) {
               # Chunk header
               $chunk_length = hex( $1 );
               return 1 if $chunk_length;

               $on_response->( $response );
               return undef; # Finished
            }

            if( defined $chunk_length and length( $$buffref ) >= $chunk_length ) {
               # Chunk body
               my $chunk = substr( $$buffref, 0, $chunk_length, "" );
               undef $chunk_length;

               $response->add_content( $chunk );

               return 1;
            }

            $on_error->( "Connection closed while awaiting chunk" ) if $closed;
            return 0;
         };
      }
      elsif( defined $content_length ) {
         if( $content_length == 0 ) {
            $on_response->( $response );
            return undef; # Finished
         }

         return sub {
            my ( $conn, $buffref, $closed ) = @_;

            if( length $$buffref >= $content_length ) {
               my $content = substr( $$buffref, 0, $content_length, "" );

               $response->content( $content );

               $on_response->( $response );
               return undef; # Finished
            }

            $on_error->( "Connection closed while awaiting body" ) if $closed;
            return 0;
         };
      }
      else {
         return sub {
            my ( $conn, $buffref, $closed ) = @_;

            return 0 unless $closed;

            my $content = $$buffref;
            $$buffref = "";

            $response->content( $content );

            $on_response->( $response );
            # $conn already closed
            return undef;
         };
      }
   };
}

# Keep perl happy; keep Britain tidy
1;

__END__

=head1 SEE ALSO

=over 4

=item *

L<RFC 2616|http://tools.ietf.org/html/rfc2616> - Hypertext Transfer Protocol
-- HTTP/1.1

=back

=head1 AUTHOR

Paul Evans E<lt>leonerd@leonerd.org.ukE<gt>
