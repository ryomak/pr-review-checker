# frozen_string_literal: true

require 'octokit'
require 'csv'
require 'dotenv/load'

class PullRequestResult
  attr_accessor :number, :title, :created_at, :review_requested_at,
                :opened_at, :first_comment_at, :approved_at, :merged_at

  def initialize(pr, events, reviews, comments, users)
    @number = pr.number
    @title = pr.title
    @created_at = pr.created_at
    @opened_at = pr.created_at
    @review_requested_at = nil
    @first_comment_at = nil
    @approved_at = nil
    @merged_at = pr.merged_at

    process_events(events)
    process_comments(comments, users)
    process_reviews(reviews, users)
  end

  private

  def process_events(events)
    events.each do |event|
      if event.event == 'review_requested' && @review_requested_at.nil?
        @review_requested_at = event.created_at
      elsif event.event == 'closed' && @merged_at.nil?
        @merged_at = event.created_at if event.commit_id == @merge_commit_sha
      end
    end
  end

  def process_comments(comments, users)
    comments.each do |comment|
      if @first_comment_at.nil? && !users.include?(comment.user.login)
        @first_comment_at = comment.created_at
      end
    end
  end

  def process_reviews(reviews, users)
    reviews.each do |review|
      if review.state == 'approved' && @approved_at.nil? && !users.include?(review.user.login)
        @approved_at = review.submitted_at
      end
    end
  end
end

class Reviewr
  def initialize(from_date, to_date)
    @client = Octokit::Client.new(access_token: ENV['GITHUB_ACCESS_TOKEN'])
    @repo = ENV['REPOSITORY']
    @users = ENV['USERS'].split(',')  # 複数ユーザをカンマ区切りで環境変数に設定
    @from_date = Date.parse(from_date)
    @to_date = Date.parse(to_date)
  end

  def fetch_pr_data
    prs = @client.pull_requests(@repo, state: :closed, per_page: 100, created:`"#{@from_date}..#{@to_date}"`)
    prs.select { |pr| @users.include?(pr.user.login) }
  end

  def fetch_events(pr_number)
    @client.issue_events(@repo, pr_number)
  end

  def fetch_reviews(pr_number)
    @client.pull_request_reviews(@repo, pr_number)
  end

  def fetch_comments(pr_number)
    @client.issue_comments(@repo, pr_number)
  end

  def collect_review_data(pr)
    events = fetch_events(pr.number)
    reviews = fetch_reviews(pr.number)
    comments = fetch_comments(pr.number)
    PullRequestResult.new(pr, events, reviews, comments, @users)
  end

  def write_to_csv(prs)
    CSV.open("pr_data.csv", "w") do |csv|
      csv << ["PR番号", "タイトル", "作成時刻", "レビュー依頼時刻", "Open時刻", "最初のコメント時刻", "アプローブ時刻", "マージ時刻"]

      prs.each do |pr|
        review_data = collect_review_data(pr)
        csv << [
          review_data.number,
          review_data.title,
          review_data.created_at,
          review_data.review_requested_at,
          review_data.opened_at,
          review_data.first_comment_at,
          review_data.approved_at,
          review_data.merged_at
        ]
      end
    end

    puts "CSVファイルにPRデータを出力しました。"
  end

  def run
    prs = fetch_pr_data
    write_to_csv(prs)
  end
end

# 実行
from_date = '2024-05-01'
to_date = '2024-06-30'   

reviewr = Reviewr.new(from_date,to_date)
reviewr.run

