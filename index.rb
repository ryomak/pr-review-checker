#frozen_string_literal: true

require 'octokit'
require 'csv'
require 'dotenv/load'


# GitHubトークンを設定
client = Octokit::Client.new(access_token: ENV['GITHUB_ACCESS_TOKEN'])

# リポジトリとユーザを設定
repo = ENV['REPOSITORY']
user = ENV['USER']


# CSVファイルの準備
CSV.open("pr_data.csv", "w") do |csv|
  # ヘッダー行を追加
  csv << ["PR番号", "タイトル", "作成時刻", "レビュー依頼時刻", "Open時刻", "最初のコメント時刻", "アプローブ時刻", "マージ時刻"]

  # PRを取得
  prs = client.pull_requests(repo, state: :closed, per_page: 100)

  prs.each do |pr|
    next unless pr.user.login == user

    pr_number = pr.number
    pr_title = pr.title
    pr_created_at = pr.created_at
    pr_opened_at = pr.created_at
    pr_review_requested_at = nil
    pr_first_comment_at = nil
    pr_approved_at = nil
    pr_merged_at = pr.merged_at

    # PRのイベントを取得
    events = client.issue_events(repo, pr_number)
    reviews = client.pull_request_reviews(repo, pr_number)
    comments = client.issue_comments(repo, pr_number)

    events.each do |event|
      if event.event == 'review_requested' && pr_review_requested_at.nil?
        pr_review_requested_at = event.created_at
      elsif event.event == 'closed' && pr.merged_at.nil?
        pr_merged_at = event.created_at if event.commit_id == pr.merge_commit_sha
      end
    end

    comments.each do |comment|
      if pr_first_comment_at.nil? && comment.user.login != user
        pr_first_comment_at = comment.created_at
      end
    end

    reviews.each do |review|
      if review.state == 'approved' && pr_approved_at.nil? && review.user.login != user
        pr_approved_at = review.submitted_at
      end
    end

    # CSVに書き込む
    csv << [
      pr_number,
      pr_title,
      pr_created_at,
      pr_review_requested_at,
      pr_opened_at,
      pr_first_comment_at,
      pr_approved_at,
      pr_merged_at
    ]
  end
end

puts "CSVファイルにPRデータを出力しました。"

