class ResourcesController < ApplicationController
  def index
    @active_tab = params[:tab] || "resources"

    faq_categories = {
      "General" => Rails.root.join("db", "faq_general.txt"),
      "Eviction & Housing Help" => Rails.root.join("db", "faq_evictionhousinghelp.txt"),
      "Data Privacy" => Rails.root.join("db", "faq_privacy.txt")
    }

    @faqs = {}

    faq_categories.each do |category, file_path|
      if File.exist?(file_path)
        raw_faqs = File.read(file_path).strip.split("\n")

        category_faqs = []
        current_question = nil
        current_answer_lines = []

        raw_faqs.each do |line|
          if line.strip.start_with?("Q: ")
            if current_question && current_answer_lines.any?
              formatted_answer = format_answer(current_answer_lines)
              category_faqs << { question: current_question, answer: formatted_answer.html_safe }
            end

            current_question = line.sub("Q: ", "").strip
            current_answer_lines = []
          elsif line.strip.start_with?("A: ") || current_question
            current_answer_lines << line.sub(/^A:\s*/, "")
          end
        end

        if current_question && current_answer_lines.any?
          formatted_answer = format_answer(current_answer_lines)
          category_faqs << { question: current_question, answer: formatted_answer.html_safe }
        end

        @faqs[category] = category_faqs
      else
        @faqs[category] = []
      end
    end
  end

  private

  def format_answer(lines)
    formatted = lines.map do |line|
      escaped_line = CGI.escapeHTML(line)
      escaped_line.gsub!(/\*\*(.*?)\*\*/, '<strong>\1</strong>')
      # regex for [text](url) links 
      escaped_line.gsub!(/\[([^\]]+)\]\(([^)\s]+)\)/, '<a href="\2" target="_blank" rel="noopener noreferrer">\1</a>')
      # regex indentations
      indent_level = (line[/\A[\t ]*/] || "").gsub("    ", "\t").count("\t")
      "<div style='margin-left: #{indent_level * 20}px;'>#{escaped_line}</div>"
    end

    formatted.join("\n")
  end
end
