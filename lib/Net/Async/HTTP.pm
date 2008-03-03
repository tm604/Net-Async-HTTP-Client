package Net::Async::HTTP;

use strict;

our $VERSION = '0.01';

use Carp;

use HTTP::Request;
use HTTP::Response;
use HTTP::Request::Common qw();

use Socket qw( SOCK_STREAM );

my $CRLF = "\x0d\x0a"; # More portable than \r\n

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

   if( $args{handle} ) {
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
