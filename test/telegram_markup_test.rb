# frozen_string_literal: true

require_relative 'test_helper'
require 'tamoz/telegram'

class TelegramMarkupTest < Minitest::Test
  def html(text) = Tamoz::Telegram::Markup.html(text)

  def test_everything_is_escaped_before_any_tag_is_added
    assert_equal 'a &lt;b&gt; &amp; <b>bold</b> <code>x&lt;y</code>', html('a <b> & **bold** `x<y`')
  end

  def test_bold_wraps_inline_code
    assert_equal 'Use <b><code>a&lt;b</code></b>', html('Use **`a<b`**')
  end

  def test_a_fenced_block_becomes_pre_without_its_language_line
    assert_equal "Try:\n<pre>puts &quot;hi&quot;</pre>\ndone", html("Try:\n```ruby\nputs \"hi\"\n```\ndone")
  end

  def test_a_longer_fence_holds_a_shorter_one_inside
    assert_equal "<pre>```\n[x](https://evil.example)\n```</pre>",
                 html("````\n```\n[x](https://evil.example)\n```\n````")
  end

  def test_an_unclosed_fence_runs_to_the_end_of_the_part
    assert_equal "<pre>line one\nline two</pre>", html("```\nline one\nline two")
  end

  def test_headings_and_links_render_and_arithmetic_stays_plain
    assert_equal "<b>Title</b>\n<a href=\"https://x.io/?a=1&amp;b=2\">docs</a> 2*3*4 snake_case",
                 html("# **Title**\n[docs](https://x.io/?a=1&b=2) 2*3*4 snake_case")
  end

  def test_overlapping_bold_and_links_never_emit_crossed_or_stray_tags
    overlapping = ['**a [b** c](http://x)', '[x](https://a.com/**y) **z**', '[x](https://a/`c`) `d`', "a\u00001\u0000b"]

    overlapping.each { |text| assert_balanced html(text) }
  end

  def assert_balanced(markup)
    open = []
    markup.scan(%r{<(/?)([a-z]+)[^>]*>}) do |closing, tag|
      closing.empty? ? open.push(tag) : assert_equal(tag, open.pop, markup)
    end

    assert_empty open, markup
  end
end
