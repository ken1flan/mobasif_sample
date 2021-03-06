package Page::Main;

=pod
----------------------------------------------------------------------
FCGI のメインループ
----------------------------------------------------------------------
=cut

use Time::HiRes;

use strict qw(vars subs);

use MobaConf;
use Common;
use MobileEnv;
use UserData;
use Request;
use Response;

use CGI;
use CGI::Cookie;
use CGI::Session;
use DA;
use Data::Dumper;
use HTMLTemplate;
use MException;
use MLog;

use Page::Base;

#---------------------------------------------------------------------
# メイン

sub main {
	my $t1 = Time::HiRes::time();

	#-------------------------
	# 初期化

	my $func = '';

	eval {
		DA::reset();

		MobileEnv::set();       # モバイル用環境変数を設定

		# Cookie設定
		my %cookies = fetch CGI::Cookie;
		$_::C = \%cookies;

		# セッション設定
		_restore_or_create_session();

		$_::F = new Request();  # リクエストパラメータを取得
		$_::U = new UserData(); # ユーザ情報を取得

		$func = $_::F->{f};
		$func = $_::DEFAULT_PAGE if ($func =~ /^\./);
		$func = $_::DEFAULT_PAGE if ($func eq '');
		$func = '.404'           if (!exists($_::PAGE{$func}));

		#-------------------------------
		# 処理ホスト名取得（Request.pm の make(SSL)BasePath で使われる）

		$ENV{MB_REQUIRED_PROTO} = '';
		$ENV{MB_REQUIRED_HOST}  = '';

		#-------------------------------
		# 接続元チェック除外

		if ($_::BYPASS_FUNC{$func} >= 2) {
			goto FUNC_START;
		}

		#-------------------------------
		# リダイレクト

		if ($_::BYPASS_FUNC{$func} >= 1) { # リダイレクト除外
			goto FUNC_START;
		}

		#-------------------------------
		# URL埋め込み情報

		# if ($_::U->{URL_INFO} &&
		# 	$_::U->{URL_INFO} ne $_::U->{URL_INFO_C}) {
		# 	redirectToRightDomain();
		# 	goto FUNC_END;
		# }
	};

	if ($@) {
		my $e   = MException::getInfo();
		my $msg = MException::makeMsg($e);
		eval { DA::rollback(); };
		MLog::write($_::LOG_FCGI_ERR,
			"UA:  $ENV{HTTP_USER_AGENT}\t".
			"REQ: $ENV{REQUEST_METHOD} $ENV{REQUEST_URI}\t".
			"REF: $ENV{HTTP_REFERER}\t".
			"$msg");
		Page::Base::pageError($e);
		goto FUNC_END;
	}

	#---------------------------
	# 指定機能をコール

FUNC_START:

	while (1) {
		eval {
			callPage($func);
		};

		if ($@) {
			my $e = MException::getInfo();
			eval { DA::rollback(); };
			if ($e->{_T} eq 'ERR') {
				my $msg = MException::makeMsg($e);
				MLog::write($_::LOG_FCGI_ERR,
					"UA:  $ENV{HTTP_USER_AGENT}\t".
					"REQ: $ENV{REQUEST_METHOD} $ENV{REQUEST_URI}\t".
					"REF: $ENV{HTTP_REFERER}\t".
					"$msg");
				Page::Base::pageError($e);
				last;
			} elsif ($e->{CHG_FUNC}) { # ファンクション変更
				$func = $e->{CHG_FUNC};
				redo;
			} elsif ($e->{REDIRECT}) { # URL指定リダイレクト
				Response::redirect($e->{REDIRECT});
				last;
			} elsif ($e->{REDIRECT2}) { # URL 再作成
				redirectToRightDomain();
				last;
			}
		}
		last;
	}

FUNC_END:
	$_::S->close();
	DA::release();
}

#---------------------------------------------------------------------

sub callPage {
	my $func = shift;

	#---------------------------
	# 要求されたページ情報を取得

	my ($reqUidSt, $reqUserSt, $reqServSt, $moduleName, $subName)
		= @{$_::PAGE{$func}};

	#---------------------------
	# UID_ST 端末情報エラー

	if ($_::U->{UID_ST} < $reqUidSt) {
		if ($ENV{MB_CARRIER_UA} eq 'D' &&
			$ENV{REQUEST_URI} !~ /[\?\&]guid=ON/) {
			MException::throw({ REDIRECT2 => 1 });
		}
		MException::throw({ CHG_FUNC => '.nouid' });
	}

	#---------------------------
	# SERV_ST サービスステータスチェック

	if ($_::U->{SERV_ST} & $reqServSt) {
		$_::U->{SERV_ST_ERR} = $_::U->{SERV_ST} & $reqServSt;
		MException::throw({ CHG_FUNC => '.servst' });
	}

	#---------------------------
	# USER_ST ユーザステータスチェック

	if ($_::U->{USER_ST} < $reqUserSt) {
		if ($_::U->{USER_ST} == 1) {
			# ***
			MException::throw({ CHG_FUNC => 'm01' });
		} else {
			MException::throw({ CHG_FUNC => 'welcome' });
		}
	}

	#---------------------------
	# メンテ中

	if ($_::MAINTAIN_FUNC{$func}) {
		MException::throw({ REDIRECT =>
			Request::makeBasePath(). $_::MAINTAIN_FUNC{$func} });
	}

	#---------------------------
	# ページ別機能をコール

	my $moduleFile = "$moduleName.pm";
	   $moduleFile =~ s#::#/#g;
	require $moduleFile;
	&{"$moduleName\::$subName"}($func);
}

#---------------------------------------------------------------------
# UA が申告したキャリア名に適したドメインにリダイレクト
# URL埋め込み情報も新しいものにセット

sub redirectToRightDomain {
	if ($ENV{REQUEST_METHOD} eq 'POST') {
		Page::Base::pageRedirect();
		return;
	}
	my $url;
	if ($ENV{MB_CARRIER_UA} eq '-') {
		$url = "http://$_::PC_HOST/";
	} else {
		if (($ENV{MB_REQUIRED_PROTO} ne 'http' && $ENV{MB_SSL}) ||
			($ENV{MB_REQUIRED_PROTO} eq 'https')) {
			$url = Request::makeSSLBasePath();
		} else {
			$url = Request::makeBasePath();
		}

		my $tmp = $ENV{REQUEST_URI};
		$tmp = "/$'" if ($tmp =~ m#/\.[^/]*/#);
		$url .= $tmp;

		if ($ENV{MB_CARRIER_UA} eq 'D' &&
			$url !~ /[\&\?]guid=ON/i) {
			$url .= ($url =~ /\?/ ? '&' : '?'). "guid=ON";
		}
	}

	Response::redirect($url);
}

sub _restore_or_create_session {
	CGI::Session->name('session_id');
	my $session_id = $_::C->{session_id} ? $_::C->{session_id}->value : undef;
	$_::S = new CGI::Session("driver:File", $session_id, {Directory=> $_::SESSION_DIR});
	$session_id = $_::S->id() unless (defined($session_id));
	$_::C->{session_id} = new CGI::Cookie(-name => 'session_id', -value => $session_id, -expires => '+1y');
	$_::S->expires('+1y');
}

1;
