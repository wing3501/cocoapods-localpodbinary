require File.expand_path('../../spec_helper', __FILE__)

module Pod
  describe Command::Localpodbinary do
    describe 'CLAide' do
      it 'registers it self' do
        Command.parse(%w{ localpodbinary }).should.be.instance_of Command::Localpodbinary
      end
    end
  end
end

