require 'test_helper'

class ArtistTest < ActiveSupport::TestCase
  def assert_artist_found(expected_name, source_url)
    artists = Artist.find_artists(source_url).to_a

    assert_equal(1, artists.size)
    assert_equal(expected_name, artists.first.name, "Testing URL: #{source_url}")
  rescue Net::OpenTimeout
    skip "Remote connection failed for #{source_url}"
  end

  def assert_artist_not_found(source_url)
    artists = Artist.find_artists(source_url).to_a
    assert_equal(0, artists.size, "Testing URL: #{source_url}")
  rescue Net::OpenTimeout
    skip "Remote connection failed for #{source_url}"
  end

  context "An artist" do
    setup do
      user = Timecop.travel(1.month.ago) {FactoryBot.create(:user)}
      CurrentUser.user = user
      CurrentUser.ip_addr = "127.0.0.1"
    end

    teardown do
      CurrentUser.user = nil
      CurrentUser.ip_addr = nil
    end

    should "parse inactive urls" do
      @artist = Artist.create(name: "blah", url_string: "-http://monet.com")
      assert_equal(["-http://monet.com"], @artist.urls.map(&:to_s))
      refute(@artist.urls[0].is_active?)
    end

    should "not allow duplicate active+inactive urls" do
      @artist = Artist.create(name: "blah", url_string: "-http://monet.com\nhttp://monet.com")
      assert_equal(1, @artist.urls.count)
      assert_equal(["-http://monet.com"], @artist.urls.map(&:to_s))
      refute(@artist.urls[0].is_active?)      
    end

    should "allow deactivating a url" do
      @artist = Artist.create(name: "blah", url_string: "http://monet.com")
      @artist.update(url_string: "-http://monet.com")
      assert_equal(1, @artist.urls.count)
      refute(@artist.urls[0].is_active?)
    end

    should "allow activating a url" do
      @artist = Artist.create(name: "blah", url_string: "-http://monet.com")
      @artist.update(url_string: "http://monet.com")
      assert_equal(1, @artist.urls.count)
      assert(@artist.urls[0].is_active?)
    end

    context "with an invalid name" do
      subject { FactoryBot.build(:artist) }

      should_not allow_value("-blah").for(:name)
      should_not allow_value("_").for(:name)
      should_not allow_value("").for(:name)
    end

    context "that has been banned" do
      setup do
        @post = FactoryBot.create(:post, :tag_string => "aaa")
        @artist = FactoryBot.create(:artist, :name => "aaa")
        @admin = FactoryBot.create(:admin_user)
        CurrentUser.scoped(@admin) { @artist.ban! }
        @post.reload
      end

      should "allow unbanning" do
        assert_difference("TagImplication.count", -1) do
          @artist.unban!
        end
        @post.reload
        @artist.reload
        assert(!@artist.is_banned?, "artist should not be banned")
        assert_equal("aaa", @post.tag_string)
      end

      should "not delete the post" do
        refute(@post.is_deleted?)
      end

      should "create a new tag implication" do
        assert_equal(1, TagImplication.where(:antecedent_name => "aaa", :consequent_name => "banned_artist").count)
        assert_equal("aaa banned_artist", @post.tag_string)
      end

      should "set the approver of the banned_artist implication" do
        ta = TagImplication.where(:antecedent_name => "aaa", :consequent_name => "banned_artist").first
        assert_equal(@admin.id, ta.approver.id)
      end
    end

    should "create a new wiki page to store any note information" do
      artist = nil
      assert_difference("WikiPage.count") do
        artist = FactoryBot.create(:artist, :name => "aaa", :notes => "testing")
      end
      assert_equal("testing", artist.notes)
      assert_equal("testing", artist.wiki_page.body)
      assert_equal(artist.name, artist.wiki_page.title)
    end

    should "update the wiki page when notes are assigned" do
      artist = FactoryBot.create(:artist, :name => "aaa", :notes => "testing")
      artist.update_attribute(:notes, "kokoko")
      artist.reload
      assert_equal("kokoko", artist.notes)
      assert_equal("kokoko", artist.wiki_page.body)
    end

    should "normalize its name" do
      artist = FactoryBot.create(:artist, :name => "  AAA BBB  ")
      assert_equal("aaa_bbb", artist.name)
    end

    should "resolve ambiguous urls" do
      bobross = FactoryBot.create(:artist, :name => "bob_ross", :url_string => "http://artists.com/bobross/image.jpg")
      bob = FactoryBot.create(:artist, :name => "bob", :url_string => "http://artists.com/bob/image.jpg")
      assert_artist_found("bob", "http://artists.com/bob/test.jpg")
    end

    should "parse urls" do
      artist = FactoryBot.create(:artist, :name => "rembrandt", :url_string => "http://rembrandt.com/test.jpg http://aaa.com")
      artist.reload
      assert_equal(["http://aaa.com", "http://rembrandt.com/test.jpg"], artist.urls.map(&:to_s).sort)
    end

    should "not allow invalid urls" do
      artist = FactoryBot.build(:artist, :url_string => "blah")
      assert_equal(false, artist.valid?)
      assert_equal(["'blah' must begin with http:// or https:// "], artist.errors["urls.url"])
    end

    should "allow fixing invalid urls" do
      artist = FactoryBot.build(:artist)
      artist.urls << FactoryBot.build(:artist_url, url: "www.example.com", normalized_url: "www.example.com")
      artist.save(validate: false)

      artist.update(url_string: "http://www.example.com")
      assert_equal(true, artist.valid?)
      assert_equal("http://www.example.com", artist.urls.map(&:to_s).join)
    end

    should "make sure old urls are deleted" do
      artist = FactoryBot.create(:artist, :name => "rembrandt", :url_string => "http://rembrandt.com/test.jpg")
      artist.url_string = "http://not.rembrandt.com/test.jpg"
      artist.save
      artist.reload
      assert_equal(["http://not.rembrandt.com/test.jpg"], artist.urls.map(&:to_s).sort)
    end

    should "not delete urls that have not changed" do
      artist = FactoryBot.create(:artist, :name => "rembrandt", :url_string => "http://rembrandt.com/test.jpg")
      old_url_ids = ArtistUrl.order("id").pluck(&:id)
      artist.url_string = "http://rembrandt.com/test.jpg"
      artist.save
      assert_equal(old_url_ids, ArtistUrl.order("id").pluck(&:id))
    end

    should "ignore pixiv.net/ and pixiv.net/img/ url matches" do
      a1 = FactoryBot.create(:artist, :name => "yomosaka", :url_string => "http://i2.pixiv.net/img18/img/evazion/14901720.png")
      a2 = FactoryBot.create(:artist, :name => "niwatazumi_bf", :url_string => "http://i2.pixiv.net/img18/img/evazion/14901720_big_p0.png")
      assert_artist_not_found("http://i2.pixiv.net/img28/img/kyang692/35563903.jpg")
    end

    should "find matches by url" do
      a1 = FactoryBot.create(:artist, :name => "rembrandt", :url_string => "http://rembrandt.com/x/test.jpg")
      a2 = FactoryBot.create(:artist, :name => "subway", :url_string => "http://subway.com/x/test.jpg")
      a3 = FactoryBot.create(:artist, :name => "minko", :url_string => "https://minko.com/x/test.jpg")

      begin
        assert_artist_found("rembrandt", "http://rembrandt.com/x/test.jpg")
        assert_artist_found("rembrandt", "http://rembrandt.com/x/another.jpg")
        assert_artist_not_found("http://nonexistent.com/test.jpg")
        assert_artist_found("minko", "https://minko.com/x/test.jpg")
        assert_artist_found("minko", "http://minko.com/x/test.jpg")
      rescue Net::OpenTimeout
        skip "network failure"
      end
    end

    should "be case-insensitive to domains when finding matches by url" do
      a1 = FactoryBot.create(:artist, name: "bkub", url_string: "http://BKUB.example.com")
      assert_artist_found(a1.name, "http://bkub.example.com")
    end

    should "not find duplicates" do
      FactoryBot.create(:artist, :name => "warhol", :url_string => "http://warhol.com/x/a/image.jpg\nhttp://warhol.com/x/b/image.jpg")
      assert_artist_found("warhol", "http://warhol.com/x/test.jpg")
    end

    should "not include duplicate urls" do
      artist = FactoryBot.create(:artist, :url_string => "http://foo.com http://foo.com")
      assert_equal(["http://foo.com"], artist.url_array)
    end

    should "hide deleted artists" do
      FactoryBot.create(:artist, :name => "warhol", :url_string => "http://warhol.com/a/image.jpg", :is_active => false)
      assert_artist_not_found("http://warhol.com/a/image.jpg")
    end

    context "when finding pixiv artists" do
      setup do
        FactoryBot.create(:artist, :name => "masao",:url_string => "http://www.pixiv.net/member.php?id=32777")
        FactoryBot.create(:artist, :name => "bkub", :url_string => "http://www.pixiv.net/member.php?id=9948")
        FactoryBot.create(:artist, :name => "ryuura", :url_string => "http://www.pixiv.net/member.php?id=8678371")
      end

      should "find the correct artist by looking up the profile url" do
        assert_artist_found("ryuura", "http://www.pixiv.net/member_illust.php?mode=medium&illust_id=48788677")
      end

      should "find the correct artist for old image URLs" do
        assert_artist_found("masao", "http://i2.pixiv.net/img04/img/syounen_no_uta/46170939.jpg")
        assert_artist_found("bkub",  "http://i1.pixiv.net/img01/img/bkubb/46239857_m.jpg")
      end

      should "find the correct artist for new image URLs" do
        assert_artist_found("masao", "http://i2.pixiv.net/c/1200x1200/img-master/img/2014/09/25/00/57/24/46170939_p0_master1200.jpg")
        assert_artist_found("masao", "http://i2.pixiv.net/img-original/img/2014/09/25/00/57/24/46170939_p0.jpg")

        assert_artist_found("bkub",  "http://i2.pixiv.net/c/1200x1200/img-master/img/2014/09/28/21/59/44/46239857_p0.jpg")
        assert_artist_found("bkub",  "http://i2.pixiv.net/img-original/img/2014/09/28/21/59/44/46239857_p0.jpg")
      end

      should "find the correct artist for page URLs" do
        assert_artist_found("masao", "http://www.pixiv.net/member_illust.php?mode=medium&illust_id=46170939")
        assert_artist_found("masao", "http://www.pixiv.net/member_illust.php?mode=big&illust_id=46170939")
        assert_artist_found("masao", "http://www.pixiv.net/member_illust.php?mode=manga&illust_id=46170939")
        assert_artist_found("masao", "http://www.pixiv.net/member_illust.php?mode=manga_big&illust_id=46170939&page=0")
        assert_artist_found("masao", "http://www.pixiv.net/i/46170939")

        assert_artist_found("bkub",  "http://www.pixiv.net/member_illust.php?mode=medium&illust_id=46239857")
        assert_artist_found("bkub",  "http://www.pixiv.net/member_illust.php?mode=big&illust_id=46239857")
        assert_artist_found("bkub",  "http://www.pixiv.net/i/46239857")
      end

      should "find nothing for bad IDs" do
        assert_artist_not_found("http://www.pixiv.net/member_illust.php?mode=medium&illust_id=32049358")
      end
    end

    context "when finding nico seiga artists" do
      setup do
        FactoryBot.create(:artist, :name => "osamari", :url_string => "http://seiga.nicovideo.jp/user/illust/7017777")
        FactoryBot.create(:artist, :name => "hakuro109", :url_string => "http://seiga.nicovideo.jp/user/illust/16265470")
      end

      should "find the artist by the profile" do
        assert_artist_found("osamari", "http://seiga.nicovideo.jp/seiga/im4937663")
        assert_artist_found("hakuro109", "http://lohas.nicoseiga.jp/priv/b9ea863e691f3a648dee5582fd6911c30dc8acab/1510092103/6424205")
      end

      should "return nothing for unknown nico seiga artists" do
        assert_artist_not_found("http://seiga.nicovideo.jp/seiga/im6605221")
        assert_artist_not_found("http://lohas.nicoseiga.jp/priv/fd195b3405b19874c825eb4d81c9196086562c6b/1509089019/6605221")
      end
    end


    context "when finding nijie artists" do
      setup do
        FactoryBot.create(:artist, :name => "evazion", :url_string => "http://nijie.info/members.php?id=236014")
        FactoryBot.create(:artist, :name => "728995",  :url_string => "http://nijie.info/members.php?id=728995")
      end

      should "find the artist" do
        assert_artist_found("evazion", "http://nijie.info/view.php?id=218944")
        assert_artist_found("728995",  "http://nijie.info/view.php?id=213043")
      end

      should "return nothing for unknown nijie artists" do
        assert_artist_not_found("http://nijie.info/view.php?id=157953")
      end
    end

    context "when finding tumblr artists" do
      setup do
        FactoryBot.create(:artist, :name => "ilya_kuvshinov", :url_string => "http://kuvshinov-ilya.tumblr.com")
        FactoryBot.create(:artist, :name => "j.k.", :url_string => "https://jdotkdot5.tumblr.com")
      end

      should "find the artist" do
        assert_artist_found("ilya_kuvshinov", "http://kuvshinov-ilya.tumblr.com/post/168641755845")
        assert_artist_found("j.k.", "https://jdotkdot5.tumblr.com/post/168276640697")
      end

      should "return nothing for unknown tumblr artists" do
        assert_artist_not_found("https://peptosis.tumblr.com/post/168162082005")
      end
    end

    should "normalize its other names" do
      artist = FactoryBot.create(:artist, name: "a1", other_names: "a1 aaa aaa AAA bbb ccc_ddd")
      assert_equal("aaa bbb ccc_ddd", artist.other_names_string)
    end

    should "search on its name should return results" do
      artist = FactoryBot.create(:artist, :name => "artist")

      assert_not_nil(Artist.search(:name => "artist").first)
      assert_not_nil(Artist.search(:name_like => "artist").first)
      assert_not_nil(Artist.search(:any_name_matches => "artist").first)
      assert_not_nil(Artist.search(:any_name_matches => "/art/").first)
    end

    should "search on other names should return matches" do
      artist = FactoryBot.create(:artist, :name => "artist", :other_names_string => "aaa ccc_ddd")

      assert_nil(Artist.search(any_other_name_like: "*artist*").first)
      assert_not_nil(Artist.search(any_other_name_like: "*aaa*").first)
      assert_not_nil(Artist.search(any_other_name_like: "*ccc_ddd*").first)
      assert_not_nil(Artist.search(name: "artist").first)
      assert_not_nil(Artist.search(:any_name_matches => "aaa").first)
      assert_not_nil(Artist.search(:any_name_matches => "/a/").first)
    end

    should "search on group name and return matches" do
      cat_or_fish = FactoryBot.create(:artist, :name => "cat_or_fish")
      yuu = FactoryBot.create(:artist, :name => "yuu", :group_name => "cat_or_fish")

      assert_equal("yuu", cat_or_fish.member_names)
      assert_not_nil(Artist.search(:group_name => "cat_or_fish").first)
      assert_not_nil(Artist.search(:any_name_matches => "cat_or_fish").first)
      assert_not_nil(Artist.search(:any_name_matches => "/cat/").first)
    end

    should "search on url and return matches" do
      bkub = FactoryBot.create(:artist, name: "bkub", url_string: "http://bkub.com")

      assert_equal([bkub.id], Artist.search(url_matches: "bkub").map(&:id))
      assert_equal([bkub.id], Artist.search(url_matches: "*bkub*").map(&:id))
      assert_equal([bkub.id], Artist.search(url_matches: "/rifyu|bkub/").map(&:id))
      assert_equal([bkub.id], Artist.search(url_matches: "http://bkub.com/test.jpg").map(&:id))
    end

    should "search on has_tag and return matches" do
      post = FactoryBot.create(:post, tag_string: "bkub")
      bkub = FactoryBot.create(:artist, name: "bkub")
      none = FactoryBot.create(:artist, name: "none")

      assert_equal(bkub.id, Artist.search(has_tag: "true").first.id)
      assert_equal(none.id, Artist.search(has_tag: "false").first.id)
    end

    should "revert to prior versions" do
      user = FactoryBot.create(:user)
      reverter = FactoryBot.create(:user)
      artist = nil
      assert_difference("ArtistVersion.count") do
        artist = FactoryBot.create(:artist, :other_names => "yyy")
      end

      assert_difference("ArtistVersion.count") do
        artist.other_names = "xxx"
        Timecop.travel(1.day.from_now) do
          artist.save
        end
      end

      first_version = ArtistVersion.first
      assert_equal(%w[yyy], first_version.other_names)
      artist.revert_to!(first_version)
      artist.reload
      assert_equal(%w[yyy], artist.other_names)
    end

    should "update the category of the tag when created" do
      tag = FactoryBot.create(:tag, :name => "abc")
      artist = FactoryBot.create(:artist, :name => "abc")
      tag.reload
      assert_equal(Tag.categories.artist, tag.category)
    end

    should "update the category of the tag when renamed" do
      tag = FactoryBot.create(:tag, :name => "def")
      artist = FactoryBot.create(:artist, :name => "abc")
      artist.name = "def"
      artist.save
      tag.reload
      assert_equal(Tag.categories.artist, tag.category)
    end

    context "when saving" do
      setup do
        @artist = FactoryBot.create(:artist, url_string: "http://foo.com")
        @artist.stubs(:merge_version?).returns(false)
      end

      should "create a new version when an url is added" do
        assert_difference("ArtistVersion.count") do
          @artist.update(:url_string => "http://foo.com http://bar.com")
          assert_equal(%w[http://bar.com http://foo.com], @artist.versions.last.urls)
        end
      end

      should "create a new version when an url is removed" do
        assert_difference("ArtistVersion.count") do
          @artist.update(:url_string => "")
          assert_equal(%w[], @artist.versions.last.urls)
        end
      end

      should "create a new version when an url is marked inactive" do
        assert_difference("ArtistVersion.count") do
          @artist.update(:url_string => "-http://foo.com")
          assert_equal(%w[-http://foo.com], @artist.versions.last.urls)
        end
      end

      should "not create a new version when nothing has changed" do
        assert_no_difference("ArtistVersion.count") do
          @artist.save
          assert_equal(%w[http://foo.com], @artist.versions.last.urls)
        end
      end

      should "not save invalid urls" do
        assert_no_difference("ArtistVersion.count") do
          @artist.update(:url_string => "http://foo.com www.example.com")
          assert_equal(%w[http://foo.com], @artist.versions.last.urls)
        end
      end
    end

    context "that is deleted" do
      setup do
        @artist = create(:artist, url_string: "https://google.com")
        @artist.update_attribute(:is_active, false)
        @artist.reload
      end

      should "preserve the url string" do
        assert_equal(1, @artist.urls.count)
      end
    end

    context "#new_with_defaults" do
      should "fetch the defaults from the given source" do
        source = "https://i.pximg.net/img-original/img/2018/01/28/23/56/50/67014762_p0.jpg"
        artist = Artist.new_with_defaults(source: source)

        assert_equal("niceandcool", artist.name)
        assert_equal("nice_and_cool", artist.other_names_string)
        assert_includes(artist.urls.map(&:url), "https://www.pixiv.net/member.php?id=906442")
        assert_includes(artist.urls.map(&:url), "https://www.pixiv.net/stacc/niceandcool")
      end

      should "fetch the defaults from the given tag" do
        source = "https://i.pximg.net/img-original/img/2018/01/28/23/56/50/67014762_p0.jpg"
        FactoryBot.create(:post, source: source, tag_string: "test_artist")
        artist = Artist.new_with_defaults(name: "test_artist")

        assert_equal("test_artist", artist.name)
        assert_equal("nice_and_cool niceandcool", artist.other_names_string)
        assert_includes(artist.urls.map(&:url), "https://www.pixiv.net/member.php?id=906442")
        assert_includes(artist.urls.map(&:url), "https://www.pixiv.net/stacc/niceandcool")
      end
    end
  end
end
